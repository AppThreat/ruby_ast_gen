# frozen_string_literal: true

require 'tempfile'

RSpec.describe RubyAstGen do
  temp_name = ""
  let(:temp_file) {
    file = Tempfile.new('test_ruby_code')
    temp_name = File.basename(file.path)
    file
  }

  after(:each) do
    temp_file.close
    temp_file.unlink
  end

  def code(s)
    temp_file.write(s)
    temp_file.rewind
  end

  it "should parse a class successfully" do
    code(<<-CODE)
class Foo
  CONST = 1
end
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should parse assignment to HEREDOCs successfully" do
    code(<<-CODE)
multi_line_string = <<-TEXT
This is a multi-line string.
You can freely write across
multiple lines using heredoc.
TEXT
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end


  it "should parse call with HEREDOC args successfully" do
    code(<<-CODE)
puts(<<-ARG1, <<-ARG2)
This is the first HEREDOC.
It spans multiple lines.
ARG1
This is the second HEREDOC.
It also spans multiple lines.
ARG2
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should create a singleton object body successfully" do
    code(<<-CODE)
class C
 class << self
  def f(x)
   x + 1
  end
 end
end
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should create an operator assignment successfully" do
    code(<<-CODE)
def foo(x)
  x += 1
end
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should create a function with a keyword option argument sucessfully" do
    code(<<-CODE)
def foo(a, bar: "default")
  puts(bar)
end
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should parse a large code snippet sucessfully" do
    code(<<-CODE)
# frozen_string_literal: true
Railsgoat::Application.routes.draw do

  get "login" => "sessions#new"
  get "signup" => "users#new"
  get "logout" => "sessions#destroy"

  get "forgot_password" => "password_resets#forgot_password"
  post "forgot_password" => "password_resets#send_forgot_password"
  get "password_resets" => "password_resets#confirm_token"
  post "password_resets" => "password_resets#reset_password"

  get "dashboard/doc" => "dashboard#doc"

  resources :sessions

  resources :users do
    get "account_settings"

    resources :retirement
    resources :paid_time_off
    resources :work_info
    resources :performance
    resources :benefit_forms
    resources :messages

    resources :pay do
      collection do
        post "update_dd_info"
        post "decrypted_bank_acct_num"
      end
    end

  end

  get "download" => "benefit_forms#download"
  post "upload" => "benefit_forms#upload"

  resources :tutorials do
    collection do
      get "credentials"
    end
  end

  resources :schedule do
    collection do
      get "get_pto_schedule"
    end
  end

  resources :admin do
    get "dashboard"
    get "get_user"
    post "delete_user"
    patch "update_user"
    get "get_all_users"
    get "analytics"
  end

  resources :dashboard do
    collection do
      get "home"
      get "change_graph"
    end
  end

  namespace :api, defaults: {format: "json"} do
    namespace :v1 do
      resources :users
      resources :mobile
    end
  end

  root to: "sessions#new"
end
    CODE
    ast = RubyAstGen::parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end
end
