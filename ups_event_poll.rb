#!/usr/bin/env ruby

# TODO
#  - Switch off deprecated gmail gem, new one is https://github.com/googleapis/google-api-ruby-client/blob/master/generated/google-apis-gmail_v1/OVERVIEW.md

Dir.chdir(File.dirname(File.expand_path(__FILE__)))

require 'rubygems'
require 'bundler'

Bundler.require

require 'google/apis/gmail_v1'
require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'action_view'
require 'fileutils'
require 'open3'

include ActionView::Helpers::DateHelper

class GmailWrapper
  OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'.freeze
  APPLICATION_NAME = 'Log To Gmail'.freeze
  SCOPE = [Google::Apis::GmailV1::AUTH_GMAIL_SEND, Google::Apis::GmailV1::AUTH_GMAIL_READONLY]

  attr_reader :config_path, :credentials_path, :token_path

  def initialize(config_path)
    @config_path = config_path
    @credentials_path = File.join(config_path, 'credentials.json')
    # The file token.yaml stores the user's access and refresh tokens, and is
    # created automatically when the authorization flow completes for the first
    # time.
    @token_path = File.join(config_path, 'token.yaml')
  end

  def service
    @service ||= load_service
  end

  def load_service
    service = Google::Apis::GmailV1::GmailService.new
    service.client_options.application_name = APPLICATION_NAME
    service.authorization = authorize
    service
  end

  # Ensure valid credentials, either by restoring from the saved credentials
  # files or intitiating an OAuth2 authorization. If authorization is required,
  # the user's default browser will be launched to approve the request.
  def authorize
    client_id = Google::Auth::ClientId.from_file(credentials_path)
    token_store = Google::Auth::Stores::FileTokenStore.new(file: token_path)
    authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
    user_id = 'default'
    credentials = authorizer.get_credentials(user_id)
    if credentials.nil?
      url = authorizer.get_authorization_url(base_url: OOB_URI)
      puts 'Open the following URL in the browser and enter the ' \
        "resulting code after authorization:\n" + url
      code = $stdin.gets
      credentials = authorizer.get_and_store_credentials_from_code(
        user_id: user_id, code: code, base_url: OOB_URI
      )
    end
    credentials
  end

  def user_email_address
    @user_email_address ||= service.get_user_profile('me').email_address
  end

  def send_self_message(subject, body)
    message = Mail.new(
      to: user_email_address,
      from: user_email_address,
      subject: subject,
      body: body
    )
    message_object = Google::Apis::GmailV1::Message.new(raw: message.to_s)
    service.send_user_message('me', message_object)
  end
end

class Notifier
  attr_reader :subject, :gmail

  def initialize(gmail, subject)
    @gmail = gmail
    @subject = subject
  end

  def notify(text)
    gmail.send_self_message(subject, text)
    puts "Notified: #{text}"
  end
end

config_path = File.join(Dir.home, '.ups_event_notification').freeze

gmail = GmailWrapper.new(config_path)
# Make sure we can authorize before running script
gmail.service

puts "Monitoring UPS status"
label = `hostname`.chomp
notifier = Notifier.new(gmail, "[#{label}] UPS Event")

status = Open3.popen3("pmset -g pslog") do |stdin, stdout, stderr, wait_thread|
  Thread.new do
    last_event_time = nil
    last_percentage = nil
    begin
      while line = stdout.gets
        # power source switch
        if matches = /^Now drawing from (.*)$/.match(line)
          if !last_event_time
            last_event_time = Time.now
            notifier.notify("UPS Event Notification started (possible computer restart)")
          else
            event_time = Time.now
            elapsed = distance_of_time_in_words(last_event_time, event_time)
            last_event_time = event_time

            notifier.notify("Now drawing from #{matches[1]}.\n#{elapsed} since last event.")
          end
        end

        # discharging update
        if matches = /\b(\d+)%; discharging; ([\d\:]+) remaining\b/.match(line)
          percentage = matches[1]
          remaining = matches[2]
          if percentage != last_percentage
            notifier.notify("UPS update: battery at #{percentage}%; #{remaining} remaining")
            last_percentage = percentage
          end
        end
      end
    rescue IOError => e
      notifier.notify("#{e.class}: #{e.message}")
      retry unless stdout.closed?
    end
  end
  Thread.new do
    begin
      while line = stderr.gets
        notifier.notify("Error: #{line}")
      end
    rescue IOError => e
      notifier.notify("#{e.class}: #{e.message}")
      retry unless stderr.closed?
    end
  end
  stdin.close
  wait_thread.value
end

unless status && status.success?
  notifier.notify("pmset errored (exit status #{status.exitstatus})")
  exit(status.exitstatus)
end
