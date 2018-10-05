require 'date'
require 'thor'
require 'fileutils'
require 'logger'
require 'date'
require 'json'
require 'fitbit_api'
require 'influxdb'

LOGFILE = File.join(Dir.home, '.fitbit.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', "fitbit.yaml")

class Fitbit < Thor
  no_commands {
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), :mode => 0755)
        FileUtils.touch logfile
        File.chmod 0644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      $logger = Logger.new STDOUT
      $logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      $logger.info 'starting'
    end
  }

  class_option :log,     :type => :boolean, :default => true, :desc => "log output to ~/.fitbit.log"
  class_option :verbose, :type => :boolean, :aliases => "-v", :desc => "increase verbosity"

  desc "record-status", "record the current data to database"
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    client = FitbitAPI::Client.new client_id:     credentials[:client_id],
                                   client_secret: credentials[:client_secret],
                                   access_token:  credentials[:access_token],
                                   refresh_token: credentials[:refresh_token],
                                   user_id:       credentials[:user_id]


    puts client.weight_logs (Date.today)

    exit  # ************

    influxdb = InfluxDB::Client.new 'fitbit'
    data = {
      values: { value: SOMEVALUE },
      timestamp: REPORTED_TIME - Time.now.utc_offset
    }
    influxdb.write_point('MEASURE', data)
  end
end

Fitbit.start
