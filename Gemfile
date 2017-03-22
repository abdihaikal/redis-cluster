# frozen_string_literal: true
source 'https://rubygems.org'

gemspec

def ruby_version?(constraint)
  Gem::Dependency.new('', constraint).match?('', RUBY_VERSION)
end

group :test do
  gem 'rubocop'
  gem 'codecov'
  gem 'simplecov'
  gem 'rake'
  gem 'rspec'
  gem 'pry'
end
