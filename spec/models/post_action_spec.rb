require 'spec_helper'
require_dependency 'post_destroyer'

describe PostAction do
  it { is_expected.to belong_to :user }
  it { is_expected.to belong_to :post }
  it { is_expected.to belong_to :post_action_type }
  it { is_expected.to rate_limit }

  let(:moderator) { Fabricate(:moderator) }
  let(:codinghorror) { Fabricate(:coding_horror) }
  let(:eviltrout) { Fabricate(:evil_trout) }
  let(:admin) { Fabricate(:admin) }
  let(:post) { Fabricate(:post) }
  let(:second_post) { Fabricate(:post, topic_id: post.topic_id) }
  let(:bookmark) { PostAction.new(user_id: post.user_id, post_action_type_id: PostActionType.types[:bookmark] , post_id: post.id) }

  describe "messaging" do

    it "doesn't generate title longer than 255 characters" do
      topic = create_topic(title: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nunc sit amet rutrum neque. Pellentesque suscipit vehicula facilisis. Phasellus lacus sapien, aliquam nec convallis sit amet, vestibulum laoreet ante. Curabitur et pellentesque tortor. Donec non.")
      post = create_post(topic: topic)
      expect { PostAction.act(admin, post, PostActionType.types[:notify_user], message: "WAT") }.not_to raise_error
    end

    it "notify moderators integration test" do
      post = create_post
      mod = moderator
      Group.refresh_automatic_groups!

      action = PostAction.act(codinghorror, post, PostActionType.types[:notify_moderators], message: "this is my special long message");

      posts = Post.joins(:topic)
                  .select('posts.id, topics.subtype, posts.topic_id')
                  .where('topics.archetype' => Archetype.private_message)
                  .to_a

      expect(posts.count).to eq(1)
      expect(action.related_post_id).to eq(posts[0].id.to_i)
      expect(posts[0].subtype).to eq(TopicSubtype.notify_moderators)

      topic = posts[0].topic

      # Moderators should be invited to the private topic, otherwise they're not permitted to see it
      topic_user_ids = topic.topic_users(true).map {|x| x.user_id}
      expect(topic_user_ids).to include(codinghorror.id)
      expect(topic_user_ids).to include(mod.id)

      # Notification level should be "Watching" for everyone
      expect(topic.topic_users(true).map(&:notification_level).uniq).to eq([TopicUser.notification_levels[:watching]])

      # reply to PM should not clear flag
      PostCreator.new(mod, topic_id: posts[0].topic_id, raw: "This is my test reply to the user, it should clear flags").create
      action.reload
      expect(action.deleted_at).to eq(nil)

      # Acting on the flag should post an automated status message
      expect(topic.posts.count).to eq(2)
      PostAction.agree_flags!(post, admin)
      topic.reload
      expect(topic.posts.count).to eq(3)
      expect(topic.posts.last.post_type).to eq(Post.types[:moderator_action])

      # Clearing the flags should not post another automated status message
      PostAction.act(mod, post, PostActionType.types[:notify_moderators], message: "another special message")
      PostAction.clear_flags!(post, admin)
      topic.reload
      expect(topic.posts.count).to eq(3)
    end

    describe 'notify_moderators' do
      before do
        PostAction.stubs(:create)
      end

      it "creates a pm if selected" do
        post = build(:post, id: 1000)
        PostCreator.any_instance.expects(:create).returns(post)
        PostAction.act(build(:user), build(:post), PostActionType.types[:notify_moderators], message: "this is my special message");
      end
    end

    describe "notify_user" do
      before do
        PostAction.stubs(:create)
        post = build(:post)
        post.user = build(:user)
      end

      it "sends an email to user if selected" do
        PostCreator.any_instance.expects(:create).returns(build(:post))
        PostAction.act(build(:user), post, PostActionType.types[:notify_user], message: "this is my special message");
      end
    end
  end

  describe "flag counts" do
    before do
      PostAction.update_flagged_posts_count
    end

    it "increments the numbers correctly" do
      expect(PostAction.flagged_posts_count).to eq(0)

      PostAction.act(codinghorror, post, PostActionType.types[:off_topic])
      expect(PostAction.flagged_posts_count).to eq(1)

      PostAction.clear_flags!(post, Discourse.system_user)
      expect(PostAction.flagged_posts_count).to eq(0)
    end

    it "should reset counts when a topic is deleted" do
      PostAction.act(codinghorror, post, PostActionType.types[:off_topic])
      post.topic.trash!
      expect(PostAction.flagged_posts_count).to eq(0)
    end

    it "should ignore validated flags" do
      post = create_post

      PostAction.act(codinghorror, post, PostActionType.types[:off_topic])
      expect(post.hidden).to eq(false)
      expect(post.hidden_at).to be_blank
      PostAction.defer_flags!(post, admin)
      expect(PostAction.flagged_posts_count).to eq(0)

      post.reload
      expect(post.hidden).to eq(false)
      expect(post.hidden_at).to be_blank

      PostAction.hide_post!(post, PostActionType.types[:off_topic])

      post.reload
      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
    end

  end

  describe "update_counters" do

    it "properly updates topic counters" do
      # we need this to test it
      TopicUser.change(codinghorror, post.topic, posted: true)

      PostAction.act(moderator, post, PostActionType.types[:like])
      PostAction.act(codinghorror, second_post, PostActionType.types[:like])

      post.topic.reload
      expect(post.topic.like_count).to eq(2)

      tu = TopicUser.get(post.topic, codinghorror)
      expect(tu.liked).to be true
      expect(tu.bookmarked).to be false

    end

  end

  describe "when a user bookmarks something" do
    it "increases the post's bookmark count when saved" do
      expect { bookmark.save; post.reload }.to change(post, :bookmark_count).by(1)
    end

    it "increases the forum topic's bookmark count when saved" do
      expect { bookmark.save; post.topic.reload }.to change(post.topic, :bookmark_count).by(1)
    end

    describe 'when deleted' do

      before do
        bookmark.save
        post.reload
        @topic = post.topic
        @topic.reload
        bookmark.deleted_at = DateTime.now
        bookmark.save
      end

      it 'reduces the bookmark count of the post' do
        expect { post.reload }.to change(post, :bookmark_count).by(-1)
      end

      it 'reduces the bookmark count of the forum topic' do
        expect { @topic.reload }.to change(post.topic, :bookmark_count).by(-1)
      end
    end
  end

  describe 'when a user likes something' do
    it 'should increase the `like_count` and `like_score` when a user likes something' do
      PostAction.act(codinghorror, post, PostActionType.types[:like])
      post.reload
      expect(post.like_count).to eq(1)
      expect(post.like_score).to eq(1)
      post.topic.reload
      expect(post.topic.like_count).to eq(1)

      # When a staff member likes it
      PostAction.act(moderator, post, PostActionType.types[:like])
      post.reload
      expect(post.like_count).to eq(2)
      expect(post.like_score).to eq(4)

      # Removing likes
      PostAction.remove_act(codinghorror, post, PostActionType.types[:like])
      post.reload
      expect(post.like_count).to eq(1)
      expect(post.like_score).to eq(3)

      PostAction.remove_act(moderator, post, PostActionType.types[:like])
      post.reload
      expect(post.like_count).to eq(0)
      expect(post.like_score).to eq(0)
    end
  end

  describe "undo/redo repeatedly" do
    it "doesn't create a second action for the same user/type" do
      PostAction.act(codinghorror, post, PostActionType.types[:like])
      PostAction.remove_act(codinghorror, post, PostActionType.types[:like])
      PostAction.act(codinghorror, post, PostActionType.types[:like])
      expect(PostAction.where(post: post).with_deleted.count).to eq(1)
      PostAction.remove_act(codinghorror, post, PostActionType.types[:like])

      # Check that we don't lose consistency into negatives
      expect(post.reload.like_count).to eq(0)
    end
  end

  describe 'when a user votes for something' do
    it 'should increase the vote counts when a user votes' do
      expect {
        PostAction.act(codinghorror, post, PostActionType.types[:vote])
        post.reload
      }.to change(post, :vote_count).by(1)
    end

    it 'should increase the forum topic vote count when a user votes' do
      expect {
        PostAction.act(codinghorror, post, PostActionType.types[:vote])
        post.topic.reload
      }.to change(post.topic, :vote_count).by(1)
    end
  end

  describe 'flagging' do

    context "flag_counts_for" do
      it "returns the correct flag counts" do
        post = create_post

        SiteSetting.stubs(:flags_required_to_hide_post).returns(7)

        # A post with no flags has 0 for flag counts
        expect(PostAction.flag_counts_for(post.id)).to eq([0, 0])

        flag = PostAction.act(eviltrout, post, PostActionType.types[:spam])
        expect(PostAction.flag_counts_for(post.id)).to eq([0, 1])

        # If staff takes action, it is ranked higher
        PostAction.act(admin, post, PostActionType.types[:spam], take_action: true)
        expect(PostAction.flag_counts_for(post.id)).to eq([0, 8])

        # If a flag is dismissed
        PostAction.clear_flags!(post, admin)
        expect(PostAction.flag_counts_for(post.id)).to eq([8, 0])
      end
    end

    it 'does not allow you to flag stuff with the same reason more than once' do
      post = Fabricate(:post)
      PostAction.act(eviltrout, post, PostActionType.types[:spam])
      expect { PostAction.act(eviltrout, post, PostActionType.types[:off_topic]) }.to raise_error(PostAction::AlreadyActed)
    end

    it 'allows you to flag stuff with another reason' do
      post = Fabricate(:post)
      PostAction.act(eviltrout, post, PostActionType.types[:spam])
      PostAction.remove_act(eviltrout, post, PostActionType.types[:spam])
      expect { PostAction.act(eviltrout, post, PostActionType.types[:off_topic]) }.not_to raise_error()
    end

    it 'should update counts when you clear flags' do
      post = Fabricate(:post)
      PostAction.act(eviltrout, post, PostActionType.types[:spam])

      post.reload
      expect(post.spam_count).to eq(1)

      PostAction.clear_flags!(post, Discourse.system_user)

      post.reload
      expect(post.spam_count).to eq(0)
    end

    it 'should follow the rules for automatic hiding workflow' do
      post = create_post
      walterwhite = Fabricate(:walter_white)

      SiteSetting.stubs(:flags_required_to_hide_post).returns(2)
      Discourse.stubs(:site_contact_user).returns(admin)

      PostAction.act(eviltrout, post, PostActionType.types[:spam])
      PostAction.act(walterwhite, post, PostActionType.types[:spam])

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached])
      expect(post.topic.visible).to eq(false)

      post.revise(post.user, { raw: post.raw + " ha I edited it " })

      post.reload

      expect(post.hidden).to eq(false)
      expect(post.hidden_reason_id).to eq(nil)
      expect(post.hidden_at).to be_blank
      expect(post.topic.visible).to eq(true)

      PostAction.act(eviltrout, post, PostActionType.types[:spam])
      PostAction.act(walterwhite, post, PostActionType.types[:off_topic])

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached_again])
      expect(post.topic.visible).to eq(false)

      post.revise(post.user, { raw: post.raw + " ha I edited it again " })

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flag_threshold_reached_again])
      expect(post.topic.visible).to eq(false)
    end

    it "hide tl0 posts that are flagged as spam by a tl3 user" do
      newuser = Fabricate(:newuser)
      post = create_post(user: newuser)

      Discourse.stubs(:site_contact_user).returns(admin)

      PostAction.act(Fabricate(:leader), post, PostActionType.types[:spam])

      post.reload

      expect(post.hidden).to eq(true)
      expect(post.hidden_at).to be_present
      expect(post.hidden_reason_id).to eq(Post.hidden_reasons[:flagged_by_tl3_user])
    end

    it "can flag the topic instead of a post" do
      post1 = create_post
      post2 = create_post(topic: post1.topic)
      post_action = PostAction.act(Fabricate(:user), post1, PostActionType.types[:spam], { flag_topic: true })
      expect(post_action.targets_topic).to eq(true)
    end

    it "will flag the first post if you flag a topic but there is only one post in the topic" do
      post = create_post
      post_action = PostAction.act(Fabricate(:user), post, PostActionType.types[:spam], { flag_topic: true })
      expect(post_action.targets_topic).to eq(false)
      expect(post_action.post_id).to eq(post.id)
    end

    it "will unhide the post when a moderator undos the flag on which s/he took action" do
      Discourse.stubs(:site_contact_user).returns(admin)

      post = create_post
      PostAction.act(moderator, post, PostActionType.types[:spam], { take_action: true })

      post.reload
      expect(post.hidden).to eq(true)

      PostAction.remove_act(moderator, post, PostActionType.types[:spam])

      post.reload
      expect(post.hidden).to eq(false)
    end

    it "will automatically close a topic due to large community flagging" do
      SiteSetting.stubs(:flags_required_to_hide_post).returns(0)

      SiteSetting.stubs(:num_flags_to_close_topic).returns(3)
      SiteSetting.stubs(:num_flaggers_to_close_topic).returns(2)

      topic = Fabricate(:topic)
      post1 = create_post(topic: topic)
      post2 = create_post(topic: topic)
      post3 = create_post(topic: topic)

      flagger1 = Fabricate(:user)
      flagger2 = Fabricate(:user)

      # reaching `num_flaggers_to_close_topic` isn't enough
      [flagger1, flagger2].each do |flagger|
        PostAction.act(flagger, post1, PostActionType.types[:inappropriate])
      end

      expect(topic.reload.closed).to eq(false)

      # clean up
      PostAction.where(post: post1).delete_all

      # reaching `num_flags_to_close_topic` isn't enough
      [post1, post2, post3].each do |post|
        PostAction.act(flagger1, post, PostActionType.types[:inappropriate])
      end

      expect(topic.reload.closed).to eq(false)

      # clean up
      PostAction.where(post: [post1, post2, post3]).delete_all

      # reaching both should close the topic
      [flagger1, flagger2].each do |flagger|
        [post1, post2, post3].each do |post|
          PostAction.act(flagger, post, PostActionType.types[:inappropriate])
        end
      end

      expect(topic.reload.closed).to eq(true)
    end

  end

  it "prevents user to act twice at the same time" do
    post = Fabricate(:post)

    # flags are already being tested
    all_types_except_flags = PostActionType.types.except(PostActionType.flag_types)
    all_types_except_flags.values.each do |action|
      expect do
        PostAction.act(eviltrout, post, action)
        PostAction.act(eviltrout, post, action)
      end.to raise_error(PostAction::AlreadyActed)
    end
  end

  describe "#create_message_for_post_action" do
    it "does not create a message when there is no message" do
      message_id = PostAction.create_message_for_post_action(Discourse.system_user, post, PostActionType.types[:spam], {})
      expect(message_id).to be_nil
    end

    [:notify_moderators, :notify_user, :spam].each do |post_action_type|
      it "creates a message for #{post_action_type}" do
        message_id = PostAction.create_message_for_post_action(Discourse.system_user, post, PostActionType.types[post_action_type], message: "WAT")
        expect(message_id).to be_present
      end
    end

  end

end
