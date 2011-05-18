#!/usr/bin/ruby
require 'rubygems'
require 'json'
require 'yaml'
require 'rest-client'
require 'active_support'
require 'readline'

class Pullr
  ORGANIZATION = 'ImpactData'
  REPO = 'Squawkbox'
  MAINLINE = 'development'
  def initialize(options = {})
    login = options.delete('login')
    token = options.delete('token')
    @repo = options.delete('repo') || REPO
    @source_tree = options.delete('source_tree') || ORGANIZATION
    @target_tree = options.delete('target_tree') || ORGANIZATION
    @target_branch = options.delete('target_branch') || MAINLINE
    credentials = token.nil? ? ":#{options.delete('password')}" : "/token:#{token}"
    base_url = "https://#{login}#{credentials}@github.com/api/v2/json/"
    @rest_urls = {
            :branches => {:list => "#{base_url}repos/show/#{@source_tree}/#{@repo}/branches"},
            :pulls => {:create => "#{base_url}pulls/#{@target_tree}/#{@repo}"},
    }
  end
  def make_pull_request(issue_number)
    branch_to_pull = "#{@source_tree}:#{find_branch issue_number}"
    puts "Create a pull request \nfrom branch #{branch_to_pull} \nto branch   #{@target_tree}:#{@target_branch}\nIssue       #{issue_number}"
    yes_no = Readline.readline('Is that OK? [yN] > ')
    if !yes_no.empty? and yes_no.downcase == 'y'
      url = @rest_urls[:pulls][:create]
      options = {:pull => {:base => @target_branch, :head => branch_to_pull}}
      puts "Posting to #{url.gsub(/\/\/.*@/,'/')} with options #{options.to_json}"
      begin
        pull_request_json = RestClient.post url, options
        puts "Received the following reply: #{pull_request_json}"
        pull_request = JSON.parse(pull_request_json)["pull"]
        # TODO - add 'certificate of build', comments?
      rescue e
        puts "ERROR - #{e.message}"
      end
    end
  end
  private
  def find_branch(issue_number)
    branches_json = RestClient.get(@rest_urls[:branches][:list])
    branches = JSON.parse(branches_json)["branches"].keys.select{|branch| /^#{issue_number}/ =~ branch}
    raise "ERROR - #{branches.count} branches found" unless branches.count == 1
    branches.first
  end
end

raise "Usage: pullr <issue-number>" unless ARGV.count == 1
issue_number = ARGV[0]
config = YAML::load(File.open(File.join(File.dirname(__FILE__), "config.yml")))
pullr = Pullr.new(config)
pullr.make_pull_request issue_number
