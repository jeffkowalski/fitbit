#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'yaml'
require 'rest-client'
require 'fitgem_oauth2'
require 'influxdb'
require 'time'
require 'base64'
require 'addressable/uri'
require 'json'

LOGFILE = File.join(Dir.home, '.log', 'fitbit.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'fitbit.yaml')

class Fitbit < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new STDOUT
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'authorize', 'authorize this application, and authenticate with the service'
  # automates https://dev.fitbit.com/apps/oauthinteractivetutorial,
  # implementing authorization code grant flow, as described here
  # https://dev.fitbit.com/build/reference/web-api/oauth2/
  def authorize
    credentials = YAML.load_file CREDENTIALS_PATH

    login = Addressable::URI.parse credentials[:authorization_uri]
    login.query_values = {
      client_id: credentials[:client_id],
      response_type: 'code',
      scope: 'activity heartrate location nutrition profile settings sleep social weight',
      redirect_uri: credentials[:callback_url]
    }
    puts 'Log in here:', login
    puts 'Then paste the URL where the browser is redirected:'
    url = STDIN.gets.chomp
    # url = 'http://localhost:3000/users/auth/fitbit/callback?code=...#_=_'
    code = url[/code=([^&#]+)/, 1]
    # puts code

    payload = Addressable::URI.new
    payload.query_values = {
      clientid: credentials[:client_id],
      grant_type: 'authorization_code',
      redirect_uri: credentials[:callback_url],
      code: code
    }
    payload = payload.to_s.delete_prefix '?'
    # puts payload
    response = RestClient.post credentials[:token_request_uri],
                               payload,
                               authorization: 'Basic ' + Base64.strict_encode64(credentials[:client_id] + ':' + credentials[:client_secret]),
                               content_type: 'application/x-www-form-urlencoded'
    # puts response
    # response = {"access_token":"...","expires_in":28800,"refresh_token":"...","scope":"...","token_type":"Bearer","user_id":"..."}
    token = JSON.parse(response)
    credentials[:access_token] = token['access_token']
    credentials[:refresh_token] = token['refresh_token']
    File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }
  rescue RestClient::ExceptionWithResponse => e
    p e, JSON.parse(e.response)
  else
    puts 'authorization successful'
  end


  desc 'record-status', 'record the current data to database'
  method_option :dry_run, type: :boolean, aliases: '-d', desc: 'do not write to database'
  def record_status
    setup_logger

    begin
      credentials = YAML.load_file CREDENTIALS_PATH

      records = begin
                  already_retried = false
                  client = FitgemOauth2::Client.new client_id: credentials[:client_id],
                                                    client_secret: credentials[:client_secret],
                                                    token: credentials[:access_token],
                                                    user_id: credentials[:user_id],
                                                    unit_system: 'en_US'
                  client.weight_logs start_date: 'today', period: '7d'
                rescue FitgemOauth2::UnauthorizedError => e
                  raise if already_retried

                  already_retried = true
                  @logger.info "caught #{e}, refreshing"
                  token = client.refresh_access_token credentials[:refresh_token]
                  credentials[:access_token] = token['access_token']
                  credentials[:refresh_token] = token['refresh_token']
                  File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }
                  retry
                end

      influxdb = InfluxDB::Client.new 'fitbit'

      records['weight'].each do |rec|
        # rec = {"bmi"=>21.21,
        #        "date"=>"2018-10-04",
        #        "fat"=>18.981000900268555,
        #        "logId"=>1538664676000,
        #        "source"=>"Aria",
        #        "time"=>"14:51:16",
        #        "weight"=>66.6}
        utc_time = Time.parse(rec['date'] + ' ' + rec['time']).to_i

        data = {
          values: { value: rec['weight'].to_f },
          timestamp: utc_time
        }
        @logger.info "weight: #{data}"
        influxdb.write_point('weight', data) unless options[:dry_run]

        data = {
          values: { value: rec['fat'].to_f },
          timestamp: utc_time
        }
        @logger.info "fat: #{data}"
        influxdb.write_point('fat', data) unless options[:dry_run]
      end
    rescue StandardError => e
      @logger.error e
    end
  end
end

Fitbit.start
