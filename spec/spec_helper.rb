ENV["SINATRA_ENV"] = "test"
require 'simplecov'
SimpleCov.start

require File.join(File.dirname(__FILE__), '..', 'app')

require 'sinatra'
require 'rack/test'
require 'yajl'
require 'database_cleaner'

# setup test environment
set :environment, :test
set :run, false
set :raise_errors, true
set :logging, false

Delayed::Worker.delay_jobs = false

def app
  Sinatra::Application
end

TEST_API_KEY = 'comments-service-test-api-key'
CommentService.config[:api_key] = TEST_API_KEY

def set_api_key_header
  current_session.header "X-Edx-Api-Key", TEST_API_KEY
end

RSpec.configure do |config|
  config.include Rack::Test::Methods
  config.treat_symbols_as_metadata_keys_with_true_values = true
  config.filter_run focus: true
  config.run_all_when_everything_filtered = true
  config.before(:each) do
    Mongoid::IdentityMap.clear
    DatabaseCleaner.clean
    [CommentThread, Comment].each do |class_|
      class_.tire.index.delete
      class_.create_elasticsearch_index
    end
  end
end

Mongoid.configure do |config|
  config.connect_to "cs_comments_service_test"
end

def parse(text)
  Yajl::Parser.parse text
end

def create_test_user(id)
  User.create!(external_id: id.to_s, username: "user#{id}")
end

def init_without_subscriptions

  [Comment, CommentThread, User, Notification, Subscription, Activity, Delayed::Backend::Mongoid::Job].each(&:delete_all).each(&:remove_indexes).each(&:create_indexes)
  Content.mongo_session[:blocked_hash].drop
  Tire.index 'comment_threads' do delete end
  CommentThread.create_elasticsearch_index
  
  commentable = Commentable.new("question_1")

  users = (1..10).map{|id| create_test_user(id)}
  user = users.first

  thread = CommentThread.new(title: "I can't solve this problem", body: "can anyone help me?", course_id: "1", commentable_id: commentable.id)
  thread.author = user
  thread.save!
  user.subscribe(thread)

  comment = thread.comments.new(body: "this problem is so easy", course_id: "1")
  comment.author = user
  comment.save!
  comment1 = comment.children.new(body: "not for me!", course_id: "1")
  comment1.author = user
  comment1.comment_thread = thread
  comment1.save!
  comment2 = comment1.children.new(body: "not for me neither!", course_id: "1")
  comment2.author = user
  comment2.comment_thread = thread
  comment2.save!

  comment = thread.comments.new(body: "see the textbook on page 69. it's quite similar", course_id: "1")
  comment.author = user
  comment.save!
  comment1 = comment.children.new(body: "thank you!", course_id: "1")
  comment1.author = user
  comment1.comment_thread = thread
  comment1.save!

  thread = CommentThread.new(title: "This problem is wrong", body: "it is unsolvable", course_id: "2", commentable_id: commentable.id)
  thread.author = user
  thread.save!
  user.subscribe(thread)

  comment = thread.comments.new(body: "how do you know?", course_id: "1")
  comment.author = user
  comment.save!
  comment1 = comment.children.new(body: "because blablabla", course_id: "1")
  comment1.author = user
  comment1.comment_thread = thread
  comment1.save!
  comment = thread.comments.new(body: "no wonder I can't solve it", course_id: "1")
  comment.author = user
  comment.save!
  comment1 = comment.children.new(body: "+1", course_id: "1")
  comment1.author = user
  comment1.comment_thread = thread
  comment1.save!

  thread = CommentThread.new(title: "I don't know what to say", body: "lol", course_id: "2", commentable_id: "something else")
  thread.author = users[1]
  thread.save!

  comment = thread.comments.new(body: "i am objectionable", course_id: "2")
  comment.author = users[2]
  comment.abuse_flaggers = [users[3]._id]
  comment.save!

  Comment.all.each do |c|
    user.vote(c, :up) # make the first user always vote up for convenience
    users[2,9].each {|user| user.vote(c, [:up, :down].sample)}
  end

  CommentThread.all.each do |c|
    user.vote(c, :up) # make the first user always vote up for convenience
    users[2,9].each {|user| user.vote(c, [:up, :down].sample)}
  end

  Content.mongo_session[:blocked_hash].insert(hash: Digest::MD5.hexdigest("blocked post"))
  # reload the global holding the blocked hashes
  CommentService.blocked_hashes = Content.mongo_session[:blocked_hash].find.select(hash: 1).each.map {|d| d["hash"]}

end

def init_with_subscriptions
  [Comment, CommentThread, User, Notification, Subscription, Activity, Delayed::Backend::Mongoid::Job].each(&:delete_all).each(&:remove_indexes).each(&:create_indexes)

  Tire.index 'comment_threads' do delete end
  CommentThread.create_elasticsearch_index

  user1 = create_test_user(1)
  user2 = create_test_user(2)

  user2.subscribe(user1)

  commentable = Commentable.new("question_1")
  user1.subscribe(commentable)
  user2.subscribe(commentable)

  thread = CommentThread.new(title: "I can't solve this problem", body: "can anyone help me?", course_id: "1", commentable_id: commentable.id)
  thread.author = user1
  user1.subscribe(thread)
  user2.subscribe(thread)
  thread.save!

  thread = thread.reload

  comment = thread.comments.new(body: "this problem is so easy", course_id: "1")
  comment.author = user2
  comment.save!
  comment1 = comment.children.new(body: "not for me!", course_id: "1")
  comment1.author = user1
  comment1.comment_thread = thread
  comment1.save!
  comment2 = comment1.children.new(body: "not for me neither!", course_id: "1")
  comment2.author = user2
  comment2.comment_thread = thread
  comment2.save!

  thread = CommentThread.new(title: "This problem is wrong", body: "it is unsolvable", course_id: "2", commentable_id: commentable.id)
  thread.author = user2
  user2.subscribe(thread)
  thread.save!

  thread = CommentThread.new(title: "I don't know what to say", body: "lol", course_id: "2", commentable_id: "something else")
  thread.author = user1
  thread.save!
end

# this method is used to test results produced using the helper function handle_threads_query
# which is used in multiple areas of the API
def check_thread_result(user, thread, hash, is_search=false, is_json=false)
  expected_keys = %w(id title body course_id commentable_id created_at updated_at)
  expected_keys += %w(anonymous anonymous_to_peers at_position_list closed user_id)
  expected_keys += %w(username votes abuse_flaggers tags type group_id pinned)
  expected_keys += %w(comments_count unread_comments_count read endorsed)
  if is_search
    expected_keys += %w(highlighted_body highlighted_title)
  end
  # these keys are checked separately, when desired, using check_thread_response_paging.
  actual_keys = hash.keys - ["children", "resp_skip", "resp_limit", "resp_total"]
  actual_keys.sort.should == expected_keys.sort

  hash["title"].should == thread.title
  hash["body"].should == thread.body
  hash["course_id"].should == thread.course_id 
  hash["anonymous"].should == thread.anonymous 
  hash["anonymous_to_peers"].should == thread.anonymous_to_peers 
  hash["commentable_id"].should == thread.commentable_id 
  hash["at_position_list"].should == thread.at_position_list 
  hash["closed"].should == thread.closed 
  hash["user_id"].should == thread.author.id
  hash["username"].should == thread.author.username
  hash["votes"]["point"].should == thread.votes["point"] 
  hash["votes"]["count"].should == thread.votes["count"] 
  hash["votes"]["up_count"].should == thread.votes["up_count"] 
  hash["votes"]["down_count"].should == thread.votes["down_count"] 
  hash["abuse_flaggers"].should == thread.abuse_flaggers
  hash["tags"].should == []
  hash["type"].should == "thread"
  hash["group_id"].should == thread.group_id
  hash["pinned"].should == thread.pinned?
  hash["endorsed"].should == thread.endorsed?
  hash["comments_count"].should == thread.comments.length

  if is_json
    hash["id"].should == thread._id.to_s
    hash["created_at"].should == thread.created_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    hash["updated_at"].should == thread.updated_at.utc.strftime("%Y-%m-%dT%H:%M:%SZ") 
  else
    hash["created_at"].should == thread.created_at
    hash["updated_at"].should == thread.updated_at
  end

  if user.nil?
    hash["unread_comments_count"].should == thread.comments.length
    hash["read"].should == false 
  else
    expected_unread_cnt = thread.comments.length # initially assume nothing has been read
    read_states = user.read_states.where(course_id: thread.course_id).to_a
    if read_states.length == 1
      read_date = read_states.first.last_read_times[thread.id.to_s]
      if read_date
        thread.comments.each do |c|
          if c.author != user and c.updated_at < read_date
            expected_unread_cnt -= 1
          end
        end
        hash["read"].should == (read_date >= thread.updated_at)
      else
        hash["read"].should == false
      end
    end
    hash["unread_comments_count"].should == expected_unread_cnt
  end
end

def check_thread_result_json(user, thread, json_response, is_search=false)
  check_thread_result(user, thread, json_response, is_search, true)
end

def check_thread_response_paging(thread, hash, resp_skip=0, resp_limit=nil, is_json=false)
  all_responses = thread.root_comments.sort({"sk" => 1}).to_a
  total_responses = all_responses.length
  hash["resp_total"].should == total_responses
  expected_response_slice = (resp_skip..(resp_limit.nil? ? total_responses : [total_responses, resp_skip + resp_limit].min)-1).to_a
  expected_response_ids = expected_response_slice.map{|i| all_responses[i]["_id"] }
  expected_response_ids.map!{|id| id.to_s } if is_json # otherwise they are BSON ObjectIds
  actual_response_ids = []
  hash["children"].each_with_index do |response, i|
    actual_response_ids << response["id"]
    response["body"].should == all_responses[expected_response_slice[i]].body
    response["user_id"].should == all_responses[expected_response_slice[i]].author_id
    response["username"].should == all_responses[expected_response_slice[i]].author_username
    comments = Comment.where({"parent_id" => response["id"]}).sort({"sk" => 1}).to_a
    expected_comment_ids = comments.map{|doc| doc["_id"] }
    expected_comment_ids.map!{|id| id.to_s } if is_json # otherwise they are BSON ObjectIds
    actual_comment_ids = []
    response["children"].each_with_index do |comment, j|
      actual_comment_ids << comment["id"]
      comment["body"].should == comments[j].body
      comment["user_id"].should == comments[j].author_id
      comment["username"].should == comments[j].author_username
    end
    actual_comment_ids.should == expected_comment_ids
  end
  actual_response_ids.should == expected_response_ids
  hash["resp_skip"].to_i.should == resp_skip
  if resp_limit.nil?
    hash["resp_limit"].should be_nil
  else
    hash["resp_limit"].to_i.should == resp_limit
  end
end

def check_thread_response_paging_json(thread, hash, resp_skip=0, resp_limit=nil)
  check_thread_response_paging(thread, hash, resp_skip, resp_limit, true)
end

# general purpose factory helpers
def make_thread(author, text, course_id, commentable_id)
  thread = CommentThread.new(title: text, body: text, course_id: course_id, commentable_id: commentable_id)
  thread.author = author
  thread.save!
  thread
end

def make_comment(author, parent, text)
  if parent.is_a?(CommentThread)
    coll = parent.comments
    thread = parent
  else
    coll = parent.children
    thread = parent.comment_thread
  end
  comment = coll.new(body: text, course_id: parent.course_id)
  comment.author = author
  comment.comment_thread = thread
  comment.save!
  comment
end

DFLT_COURSE_ID = "xyz"

def setup_10_threads
  User.all.delete
  Content.all.delete

  @threads = {}
  @comments = {}
  @users = {}
  10.times do |i|
    author = create_test_user(i+100)
    @users["u#{i+100}"] = author
    thread = make_thread(author, "t#{i}", DFLT_COURSE_ID, "pdq")
    @threads["t#{i}"] = thread
    5.times do |j|
      comment = make_comment(author, thread, "t#{i} c#{j}")
      @comments["t#{i} c#{j}"] = comment
    end
  end
  @default_order = 10.times.map {|i| "t#{i}"}.reverse
end
