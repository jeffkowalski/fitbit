#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'yaml'
require 'fitgem_oauth2'
require 'influxdb'
require 'time'

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
  class_option :dry_run, type: :boolean, aliases: '-d', desc: 'do not write to database'

  desc 'record-status', 'record the current data to database'
  def record_status
    setup_logger

    begin
      credentials = YAML.load_file CREDENTIALS_PATH

      client = FitgemOauth2::Client.new client_id: credentials[:client_id],
                                        client_secret: credentials[:client_secret],
                                        token: credentials[:access_token],
                                        user_id: credentials[:user_id],
                                        unit_system: 'en_US'

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
