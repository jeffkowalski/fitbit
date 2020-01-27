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
  # automates this: https://dev.fitbit.com/apps/oauthinteractivetutorial
  def authorize
    credentials = YAML.load_file CREDENTIALS_PATH
    puts 'Log in here:'
    puts 'https://www.fitbit.com/oauth2/authorize?' \
         'response_type=code&' \
         "client_id=#{credentials[:client_id]}&" \
         'redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fusers%2Fauth%2Ffitbit%2Fcallback&' \
         'scope=activity%20heartrate%20location%20nutrition%20profile%20settings%20sleep%20social%20weight&' \
         'expires_in=31536000'
    puts 'Then paste the URL where the browser is redirected:'
    url = STDIN.gets.chomp
    # url = 'http://localhost:3000/users/auth/fitbit/callback?code=...#_=_'
    code = url[/code=([^&#]+)/, 1]
    puts code

    payload = "clientId=#{credentials[:client_id]}&grant_type=authorization_code&" \
              "redirect_uri=http%3A%2F%2Flocalhost%3A3000%2Fusers%2Fauth%2Ffitbit%2Fcallback&code=#{code}"
    puts payload
    response = RestClient.post 'https://api.fitbit.com/oauth2/token',
                               payload,
                               authorization: 'Basic ' + Base64.encode64(credentials[:client_id] + ':' + credentials[:client_secret]),
                               content_type: 'application/x-www-form-urlencoded'
    puts response
    # {"access_token":"...","expires_in":28800,"refresh_token":"...","scope":"...","token_type":"Bearer","user_id":"..."}
    token = JSON.parse(response)
    credentials[:access_token] = token['access_token']
    credentials[:refresh_token] = token['refresh_token']
    File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }
  rescue StandardError => e
    p e
  end


  desc 'record-status', 'record the current data to database'
  method_option :dry_run, type: :boolean, aliases: '-d', desc: 'do not write to database'
  def record_status
    setup_logger

    begin
      credentials = YAML.load_file CREDENTIALS_PATH

      client = FitgemOauth2::Client.new client_id: credentials[:client_id],
                                        client_secret: credentials[:client_secret],
                                        token: credentials[:access_token],
                                        user_id: credentials[:user_id],
                                        unit_system: 'en_US'
      token = client.refresh_access_token credentials[:refresh_token]
      credentials[:access_token] = token['access_token']
      credentials[:refresh_token] = token['refresh_token']
      File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }
      records = client.weight_logs start_date: 'today', period: '7d'

      influxdb = InfluxDB::Client.new 'fitbit'

      records['weight'].each do |rec|
        # {"bmi"=>21.21,
        #  "date"=>"2018-10-04",
        #  "fat"=>18.981000900268555,
        #  "logId"=>1538664676000,
        #  "source"=>"Aria",
        #  "time"=>"14:51:16",
        #  "weight"=>66.6}
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
