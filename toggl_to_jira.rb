#!/usr/bin/ruby 
require "net/https"
require "uri"
require 'cgi'
require 'rubygems'
require 'active_support/all'
require 'json'
require 'jira4r'
require 'yaml'

CONFIG = YAML.load_file(File.expand_path(File.dirname(__FILE__)) + '/config.yml') unless defined? CONFIG
CONFIG['start_time'] ||= Time.now.beginning_of_day.iso8601
CONFIG['start_time'] = CONFIG['start_time'].days.ago.iso8601 if CONFIG['start_time'].is_a?(Fixnum)
uri = URI.parse("https://www.toggl.com/api/v6/time_entries.json?start_date=#{CGI.escape(CONFIG['start_time'])}" + 
								(CONFIG['end_time'].blank? ? '' : "&end_date=#{CGI.escape(CONFIG['end_time'])}"))
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_NONE

puts "Connecting to toggl starting from #{CONFIG['start_time']}"
request = Net::HTTP::Get.new(uri.request_uri)
request.basic_auth(CONFIG['toggl_key'], "api_token")

response = http.request(request)
begin
	json = JSON.parse(response.body)
	raise unless json['data']
rescue 
	puts "Request to toggl failed"
	puts $! 
	puts response.inspect 
	exit(1) 
end

entries = json['data']
puts "Got #{entries.length} entries from toggl"

IMPORTED_FILE = File.expand_path(File.dirname(__FILE__)) + "/imported.yml"
imported = (YAML.load_file(IMPORTED_FILE) rescue [])

puts "Connecting to JIRA"
begin
	logger = Logger.new(STDERR)
	logger.sev_threshold = Logger::WARN
	jira = Jira4R::JiraTool.new(2, CONFIG['jira_url'])
	jira.logger = logger
	jira.login CONFIG['jira_user'], CONFIG['jira_pass']
rescue
	puts "Failed to login to JIRA"
	puts $!
	exit(1)
end
puts "Successfully login to JIRA as #{CONFIG['jira_user']}"

entries.each do |entry|
	id = entry['id']
	start = Time.iso8601(entry['start'])
	duration = entry['duration'].to_i
	desc = entry['description'] || ''
	desc += " #{entry['project']['name']}" if entry['project'] and entry['project']['name']
	jira_key = entry['tag_names'][0] if entry['tag_names'].length && entry['tag_names'][0] =~ /([A-Z]+-\d+)/

	if imported.include?(id)
		puts "Skip #{jira_key} '#{desc}' as it was already imported"
	elsif entry['duration'].to_i < 0
		puts "Skip #{jira_key} '#{desc}' as it's still running"
	elsif entry['duration'].to_i < 60
		puts "Skip #{jira_key} '#{desc}' as its duration is less than 1 minute"
	elsif jira_key.blank?
		puts "Skip #{jira_key} '#{desc}' as it doesn't have a JIRA ticket key"
	else
		remoteWorklog = Jira4R::V2::RemoteWorklog.new
		remoteWorklog.comment = "#{desc} , generated from toggl_to_jira script"
		remoteWorklog.startDate = start
		remoteWorklog.timeSpent = "#{(duration / 60.0).round}m"
		puts "Add worklog #{remoteWorklog.timeSpent.rjust(4)} from #{remoteWorklog.startDate.localtime.strftime('%b %e, %l:%M %p')} to ticket #{jira_key} #{desc}"
		begin
			jira.addWorklogAndAutoAdjustRemainingEstimate(jira_key, remoteWorklog)
			imported.push id
			imported.shift if imported.size > 500 # avoid imported list increasing infinitely
			File.open(IMPORTED_FILE, "w") {|f| f.write(imported.to_yaml) }
		rescue SOAP::Error => error
			STDERR.puts "Error: " + error
		end
	end
end
