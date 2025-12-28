# frozen_string_literal: true

require "tempfile"

RSpec.describe RubyAstGen do
  temp_name = ""
  let(:temp_file) do
    file = Tempfile.new("test_ruby_code")
    temp_name = File.basename(file.path)
    file
  end

  after(:each) do
    temp_file.close
    temp_file.unlink
  end

  def code(s)
    temp_file.write(s)
    temp_file.rewind
  end

  it "should parse a class successfully" do
    code(<<~CODE)
      class Foo
        CONST = 1
      end
    CODE
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should parse assignment to HEREDOCs successfully" do
    code(<<~CODE)
      multi_line_string = <<-TEXT
      This is a multi-line string.
      You can freely write across
      multiple lines using heredoc.
      TEXT
    CODE
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should parse call with HEREDOC args successfully" do
    code(<<~CODE)
      puts(<<-ARG1, <<-ARG2)
      This is the first HEREDOC.
      It spans multiple lines.
      ARG1
      This is the second HEREDOC.
      It also spans multiple lines.
      ARG2
    CODE
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should create a singleton object body successfully" do
    code(<<~CODE)
      class C
       class << self
        def f(x)
         x + 1
        end
       end
      end
    CODE
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should create an operator assignment successfully" do
    code(<<~CODE)
      def foo(x)
        x += 1
      end
    CODE
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should create a function with a keyword option argument sucessfully" do
    code(<<~CODE)
      def foo(a, bar: "default")
        puts(bar)
      end
    CODE
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  it "should parse a large code snippet sucessfully" do
    code(<<~CODE)
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
    ast = RubyAstGen.parse_file(temp_file.path, temp_name)
    expect(ast).not_to be_nil
  end

  context "Literals" do
    it "parses bare true and false" do
        code(<<~RUBY)
        a = true
        b = false
        RUBY
        ast = RubyAstGen.parse_file(temp_file.path, temp_name)
        expect(ast).not_to be_nil
    end
    
    it "parses boolean literals in an array" do
        code("[true, false, nil]")
        ast = RubyAstGen.parse_file(temp_file.path, temp_name)
        expect(ast).not_to be_nil
    end

    it "parses complex and rational literals" do
      code(<<~RUBY)
        c = 42i
        r = 3.14r
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end
  end

  context "Pattern Matching Extensions" do
    it "parses constant patterns (const_pattern)" do
      code(<<~RUBY)
        val = 1
        case val
        in Integer
          :int
        in String
          :str
        end
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end

    it "parses variable capture in array patterns (match_write)" do
      code(<<~RUBY)
        case [1, 2]
        in [a, b]
          a + b
        end
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end

    it "parses find patterns" do
      code(<<~RUBY)
        case [1, 2, 3]
        in [*, 2, *]
          :found
        end
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end

    it "parses pinned array patterns" do
        code(<<~RUBY)
            x = 10
            case [x, 2, 3]
            in [^x, y, z]
            :matched
            end
        RUBY
        ast = RubyAstGen.parse_file(temp_file.path, temp_name)
        expect(ast).not_to be_nil
    end
        
    it "parses pinned hash patterns" do
        code(<<~RUBY)
            x = :foo
            case {a: x, b: 2}
            in {a: ^x, b: y}
            :ok
            end
        RUBY
        ast = RubyAstGen.parse_file(temp_file.path, temp_name)
        expect(ast).not_to be_nil
    end
  end

  context "Ruby 3.4 syntax", if: (Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4")) do
    it "parses default block parameter in do/end blocks" do
      code(<<~RUBY)
        [10, 20, 30].select do
          it > 15
        end
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end
    
    it "parses nested `it` blocks correctly" do
      code(<<~RUBY)
        [1, 2, 3].map { it * 2 }.each { puts it }
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end
    
    it "parses simple method call with **nil keyword splat" do
      code(<<~RUBY)
        send_email(to: "hello@appthreat.com", **nil)
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end
    
    it "parses a method definition using **nil as default keyword args" do
      code(<<~RUBY)
        def configure(**nil)
          opts
        end
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end
    
    it "parses a chain mixing `it` and **nil" do
      code(<<~RUBY)
        [4,5,6].reject { it.even? }.map { process(it, **nil) }
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end
    
    it "parses the new default block parameter `it`" do
      code(<<~RUBY)
        result = [1, 2, 3].map { it * 2 }
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end

    it "parses keyword splatting of `nil` (`**nil` → `{}`)" do
      code(<<~RUBY)
        def handle_options(**opts); opts; end
        handle_options(**nil)
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).not_to be_nil
    end

    it "raises on block‐arg in index assignment (syntax removed in 3.4)" do
      code(<<~RUBY)
        numbers = []
        even_block = ->(x) { x.even? }
        numbers[&even_block] = 10
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).to be_nil
    end

    it "raises on keyword‐arg in index assignment (syntax removed in 3.4)" do
      code(<<~RUBY)
        class Matrix
          def []=(*args, **kwargs); end
        end
        matrix = Matrix.new
        matrix[5, axis: :y] = 8
      RUBY
      ast = RubyAstGen.parse_file(temp_file.path, temp_name)
      expect(ast).to be_nil
    end
  end
end