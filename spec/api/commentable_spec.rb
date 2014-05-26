require 'spec_helper'
require 'unicode_shared_examples'

describe "app" do
  describe "commentables" do

    before(:each) do
      init_without_subscriptions
      set_api_key_header
    end

    describe "DELETE /api/v1/:commentable_id/threads" do
      it "delete all associated threads and comments of a commentable" do
        delete '/api/v1/question_1/threads'
        last_response.should be_ok
        Commentable.find("question_1").comment_threads.count.should == 0
      end
      it "handle normally when commentable does not exist" do
        delete '/api/v1/does_not_exist/threads'
        last_response.should be_ok
      end
    end
    describe "GET /api/v1/:commentable_id/threads" do
      it "get all comment threads associated with a commentable object" do
        get "/api/v1/question_1/threads"
        last_response.should be_ok
        response = parse last_response.body
        threads = response['collection']
        threads.length.should == 2
        threads.index{|c| c["body"] == "can anyone help me?"}.should_not be_nil
        threads.index{|c| c["body"] == "it is unsolvable"}.should_not be_nil
      end
      it "returns an empty array when the commentable object does not exist (no threads)" do
        get "/api/v1/does_not_exist/threads"
        last_response.should be_ok
        response = parse last_response.body
        threads = response['collection']
        threads.length.should == 0
      end

      def test_unicode_data(text)
        commentable_id = "unicode_commentable"
        thread = make_thread(User.first, text, "unicode_course", commentable_id)
        make_comment(User.first, thread, text)
        get "/api/v1/#{commentable_id}/threads"
        last_response.should be_ok
        result = parse(last_response.body)["collection"]
        result.should_not be_empty
        check_thread_result_json(nil, thread, result.first)
      end

      include_examples "unicode data"
    end
    describe "POST /api/v1/:commentable_id/threads" do
      let(:default_params) do
        {title: "Interesting question", body: "cool", course_id: "1", user_id: "1"}
      end
      it "create a new comment thread for the commentable object" do
        old_count = CommentThread.count
        post '/api/v1/question_1/threads', default_params
        last_response.should be_ok
        CommentThread.count.should == old_count + 1
        CommentThread.where(title: "Interesting question").first.should_not be_nil
      end
      it "allows anonymous thread" do
        old_count = CommentThread.count
        post '/api/v1/question_1/threads', default_params.merge(anonymous: true)
        last_response.should be_ok
        CommentThread.count.should == old_count + 1
        c = CommentThread.where(title: "Interesting question").first
        c.should_not be_nil
        c["anonymous"].should be_true
      end
      it "create a new comment thread for a new commentable object" do
        post '/api/v1/does_not_exist/threads', default_params
        last_response.should be_ok
        Commentable.find("does_not_exist").comment_threads.length.should == 1
        Commentable.find("does_not_exist").comment_threads.first.body.should == "cool"
      end
      it "returns error when title, body or course id does not exist" do
        params = default_params.dup
        params.delete(:title)
        post '/api/v1/question_1/threads', params
        last_response.status.should == 400
        params = default_params.dup
        params.delete(:body)
        post '/api/v1/question_1/threads', params
        last_response.status.should == 400
        params = default_params.dup
        params.delete(:course_id)
        post '/api/v1/question_1/threads', params
        last_response.status.should == 400
      end
      it "returns error when title or body is blank (only consists of spaces and new lines)" do
        post '/api/v1/question_1/threads', default_params.merge(title: "     ")
        last_response.status.should == 400
        post '/api/v1/question_1/threads', default_params.merge(body: "     \n    \n")
        last_response.status.should == 400
      end
      it "returns 503 when the post content is blocked" do
        post '/api/v1/question_1/threads', default_params.merge(body: "BLOCKED POST")
        last_response.status.should == 503
        parse(last_response.body).first.should == I18n.t(:blocked_content_with_body_hash, :hash => Digest::MD5.hexdigest("blocked post"))
      end

      def test_unicode_data(text)
        commentable_id = "unicode_commentable"
        post "/api/v1/#{commentable_id}/threads", default_params.merge(body: text, title: text)
        last_response.should be_ok
        CommentThread.where(commentable_id: commentable_id, body: text, title: text).should_not be_empty
      end

      include_examples "unicode data"
    end
  end
end
