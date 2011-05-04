#!/usr/bin/ruby
require 'rubygems'
require 'json'
require 'yaml'
require 'rest-client'
require 'active_support'

class Pullr
  ORGANIZATION = 'ImpactData'
  REPO = 'Squawkbox'
  BASE_BRANCH = 'development'
  def initialize(options = {})
    login = options.delete('login')
    token = options.delete('token')
    credentials = token.nil? ? ":#{options.delete('password')}" : "/token:#{token}"
    base_url = "https://#{login}#{credentials}@github.com/api/v2/json/"
    @rest_urls = {
            :branches => {:list => "#{base_url}repos/show/#{ORGANIZATION}/#{REPO}/branches"},
            :pulls => {:create => "#{base_url}pulls/#{ORGANIZATION}/#{REPO}"},
    }
  end
  def make_pull_request(issue_number = nil)
    branch_to_pull = find_branch issue_number
    pull_request_json = RestClient.post @rest_urls[:pulls][:create],
                                        :pull => {:base => BASE_BRANCH,
                                                  :head => branch_to_pull,
                                                  :issue =>issue_number}
    pull_request = JSON.parse(pull_request_json)["pull"]
    # TODO - add 'certificate of build', comments?
  end
  private
  def find_branch(issue_number)
    branches_json = RestClient.get(@rest_urls[:branches][:list])
    branches = JSON.parse(branches_json)["branches"].keys.select{|branch| /^#{issue_number}/ =~ branch}
    raise "#{branches.count} branches found " unless branches.count == 1
    branches.first
  end
end

raise "Usage: pullr <issue-number>" unless ARGV.count == 1
issue_number = ARGV[0]
config = YAML::load(File.open(File.join(File.dirname(__FILE__), "config.yml")))
pullr = Pullr.new(config)
pullr.make_pull_request issue_number
