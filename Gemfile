# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "ostruct", "~> 0.6.3"
gem "parser", "~> 3.3.12.0"
gem "prism", "~> 1.9"

# Development only. The group is load-bearing beyond bundler: the gems outside
# it are exactly what the SEA builds vendor, and spec/sea_bundle_spec.rb reads
# this file to hold the build scripts' embedded copies to that set.
group :development do
  gem "rake", "~> 13.4.2"
  gem "rspec", "~> 3.13.2"
end
