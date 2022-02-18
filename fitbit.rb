#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

class Fitbit < RecorderBotBase
  desc 'authorize', 'authorize this application, and authenticate with the service'
  # automates https://dev.fitbit.com/apps/oauthinteractivetutorial,
  # implementing authorization code grant flow, as described here
  # https://dev.fitbit.com/build/reference/web-api/oauth2/
  def authorize
    credentials = load_credentials

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

    store_credentials credentials
  rescue RestClient::ExceptionWithResponse => e
    p e, JSON.parse(e.response)
  else
    puts 'authorization successful'
  end

  no_commands do
    def main
      credentials = load_credentials

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
                  store_credentials credentials
                  retry
                end

      influxdb = InfluxDB::Client.new 'fitbit' unless options[:dry_run]
      data = []
      records['weight'].each do |rec|
        # rec = {"bmi"=>21.21,
        #        "date"=>"2018-10-04",
        #        "fat"=>18.981000900268555,
        #        "logId"=>1538664676000,
        #        "source"=>"Aria",
        #        "time"=>"14:51:16",
        #        "weight"=>66.6}
        utc_time = Time.parse(rec['date'] + ' ' + rec['time']).to_i

        %w[bmi fat weight].each do |measure|
          data.push({ series: measure,
                      values: { value: rec[measure].to_f },
                      timestamp: utc_time })
          @logger.info "#{measure}: #{data}"
        end
      end
      influxdb.write_points(data) unless options[:dry_run]
    end
  end
end

Fitbit.start
