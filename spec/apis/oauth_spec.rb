#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/api_spec_helper')

if Canvas.redis_enabled? # eventually we're going to have to just require redis to run the specs

describe "OAuth2", :type => :integration do

  before do
    @key = DeveloperKey.create!
    @client_id = @key.id
    @client_secret = @key.api_key
  end

  it "should require a valid client id" do
    get "/login/oauth2/auth", :response_type => 'code', :redirect_uri => 'urn:ietf:wg:oauth:2.0:oob'
    response.should be_client_error
  end

  it "should reject any redirect_uri except the oob marker" do
    get "/login/oauth2/auth", :response_type => 'code', :redirect_uri => 'https://my-web-app.com/oauth/response/', :client_id => @client_id
    response.should be_client_error

    get "/login/oauth2/auth", :response_type => 'code', :client_id => @client_id
    response.should be_redirect

    get "/login/oauth2/auth", :response_type => 'code', :client_id => @client_id, :redirect_uri => 'urn:ietf:wg:oauth:2.0:oob'
    response.should be_redirect
  end

  it "should require a valid code to get an access_token" do
    post "/login/oauth2/token", :client_id => @client_id, :client_secret => @client_secret, :code => 'asdf'
    response.should be_client_error
  end

  it "should continue to allow developer key + basic auth access" do
    # this will continue to be supported until we notify api users and explicitly phase it out
    user_with_pseudonym(:active_user => true, :username => 'test1@example.com', :password => 'test123')
    course_with_teacher(:user => @user)

    get "/api/v1/courses.json"
    response.should be_client_error
    get "/api/v1/courses.json?api_key=#{@key.api_key}"
    response.should be_client_error
    get "/api/v1/courses.json?api_key=#{@key.api_key}", {}, { :authorization => ActionController::HttpAuthentication::Basic.encode_credentials('test1@example.com', 'failboat') }
    response.should be_client_error
    get "/api/v1/courses.json", {}, { :authorization => ActionController::HttpAuthentication::Basic.encode_credentials('test1@example.com', 'test123') }
    response.should be_success
    get "/api/v1/courses.json?api_key=#{@key.api_key}", {}, { :authorization => ActionController::HttpAuthentication::Basic.encode_credentials('test1@example.com', 'test123') }
    response.should be_success
    reset!

    # don't need developer key when we have an actual application session
    post '/login', 'pseudonym_session[unique_id]' => 'test1@example.com', 'pseudonym_session[password]' => 'test123'
    get "/api/v1/courses.json", {}
    response.should be_success
    JSON.parse(response.body).size.should == 1
    reset!

    post "/api/v1/courses/#{@course.id}/assignments.json", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' } }
    response.should be_client_error
    post "/api/v1/courses/#{@course.id}/assignments.json", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' } }, { :authorization => ActionController::HttpAuthentication::Basic.encode_credentials('test1@example.com', 'test123') }
    response.should be_client_error
    post "/api/v1/courses/#{@course.id}/assignments.json?api_key=#{@key.api_key}", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' } }, { :authorization => ActionController::HttpAuthentication::Basic.encode_credentials('test1@example.com', 'test123') }
    response.should be_success
    @course.assignments.count.should == 1
    @course.assignments.first.title.should == 'test assignment'
    @course.assignments.first.points_possible.should == 5.3
    # still need an authenticity token for posts when they have an actual application session
    reset!
    post '/login', 'pseudonym_session[unique_id]' => 'test1@example.com', 'pseudonym_session[password]' => 'test123'
    post "/api/v1/courses/#{@course.id}/assignments.json", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' }, :authenticity_token => 'asdf' }
    response.should be_client_error
    $now = true
    post "/api/v1/courses/#{@course.id}/assignments.json", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' }, :authenticity_token => session[:_csrf_token] }
    response.should be_success
    @course.assignments.count.should == 2
  end

  describe "oauth2 native app flow" do
    def flow(opts = {})
      enable_forgery_protection do
        user_with_pseudonym(:active_user => true, :username => 'test1@example.com', :password => 'test123')
        course_with_teacher(:user => @user)

        # step 1
        get "/login/oauth2/auth", :response_type => 'code', :client_id => @client_id, :redirect_uri => 'urn:ietf:wg:oauth:2.0:oob'
        response.should redirect_to(login_url(:re_login => true))

        yield

        # step 2
        response.should be_redirect
        response['Location'].should match(%r{/login/oauth2/auth?})
        code = response['Location'].match(/code=([^\?&]+)/)[1]
        code.should be_present

        get response['Location']
        response.should be_success

        # make sure the user is now logged out, or the app also has full access to their session
        get '/'
        response.should be_redirect
        response['Location'].should == 'http://www.example.com/login'

        # we have the code, we can close the browser session
        if opts[:basic_auth]
          post "/login/oauth2/token", { :code => code }, { :authorization => ActionController::HttpAuthentication::Basic.encode_credentials(@client_id, @client_secret) }
        else
          post "/login/oauth2/token", :client_id => @client_id, :client_secret => @client_secret, :code => code
        end
        response.should be_success
        response.header['content-type'].should == 'application/json; charset=utf-8'
        json = JSON.parse(response.body)
        token = json['access_token']
        reset!

        # try an api call
        get "/api/v1/courses.json?access_token=1234"
        response.should be_client_error

        get "/api/v1/courses.json?access_token=#{token}"
        response.should be_success
        json = JSON.parse(response.body)
        json.size.should == 1
        json.first['enrollments'].should == [{'type' => 'teacher'}]
        AccessToken.last.token.should == token

        # post requests should work with nothing but an access token
        post "/api/v1/courses/#{@course.id}/assignments.json?access_token=1234", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' } }
        response.should be_client_error
        post "/api/v1/courses/#{@course.id}/assignments.json?access_token=#{token}", { :assignment => { :name => 'test assignment', :points_possible => '5.3', :grading_type => 'points' } }
        response.should be_success
        @course.assignments.count.should == 1
        @course.assignments.first.title.should == 'test assignment'
        @course.assignments.first.points_possible.should == 5.3
      end
    end

    it "should execute for password/ldap login" do
      flow do
        get response['Location']
        response.should be_success
        post "/login", :pseudonym_session => { :unique_id => 'test1@example.com', :password => 'test123' }
      end
    end

    it "should execute for saml login" do
      Setting.set_config("saml", {})
      account = account_with_saml(:account => Account.default)
      flow do
        Onelogin::Saml::Response.stub(:new).and_return {
          r = mock(:response, :is_valid? => true, :success_status? => true, :name_id => 'test1@example.com', :name_qualifier => nil, :session_index => nil)
          r.stub(:settings=)
          r.stub(:logger=)
          r
        }

        get 'saml_consume', :SAMLResponse => "foo"
      end
    end

    it "should execute for cas login" do
      flow do
        account = account_with_cas(:account => Account.default)

        cas = CASClient::Client.new(:cas_base_url => account.account_authorization_config.auth_base)
        cas.should_receive(:validate_service_ticket).and_return { |st|
          st.response = CASClient::ValidationResponse.new("yes\n#{@user.pseudonyms.first.unique_id}\n")
        }
        CASClient::Client.stub(:new).and_return(cas)

        get response['Location']
        response.should redirect_to(cas.add_service_to_login_url(login_url))

        get '/login', :ticket => 'ST-abcd'
        session[:cas_login].should == true
      end
    end

    it "should allow http basic auth for the app auth" do
      flow(:basic_auth => true) do
        get response['Location']
        response.should be_success
        post "/login", :pseudonym_session => { :unique_id => 'test1@example.com', :password => 'test123' }
      end
    end

    it "should require the correct client secret" do
      # step 1
      get "/login/oauth2/auth", :response_type => 'code', :client_id => @client_id, :redirect_uri => 'urn:ietf:wg:oauth:2.0:oob'
      response.should redirect_to(login_url(:re_login => true))

      get response['Location']
      response.should be_success

      user_with_pseudonym(:active_user => true, :username => 'test1@example.com', :password => 'test123')
      course_with_teacher(:user => @user)
      post "/login", :pseudonym_session => { :unique_id => 'test1@example.com', :password => 'test123' }

      # step 2
      response.should be_redirect
      response['Location'].should match(%r{/login/oauth2/auth?})
      code = response['Location'].match(/code=([^\?&]+)/)[1]
      code.should be_present

      # we have the code, we can close the browser session
      post "/login/oauth2/token", :client_id => @client_id, :client_secret => 'nuh-uh', :code => code
      response.should be_client_error
    end
  end
end

end
