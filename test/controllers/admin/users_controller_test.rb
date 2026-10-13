require "test_helper"
require_relative "../../support/airtable_stub"

class Admin::UsersControllerTest < ActionController::TestCase
  include AirtableStub
  tests Admin::UsersController

  setup do
    @admin = users(:two)
    @admin.update!(admin: true)
    @previous_admins = ENV["ADMIN_SLACK_IDS"]
    ENV["ADMIN_SLACK_IDS"] = @admin.slack_id
    session[:user_id] = @admin.id
  end

  teardown { @previous_admins.nil? ? ENV.delete("ADMIN_SLACK_IDS") : ENV["ADMIN_SLACK_IDS"] = @previous_admins }

  test "moves a legacy member to the current NDA flow without deleting their old signature" do
    user = users(:one)
    legacy = create_legacy_signature(user)

    assert_difference("AdminAction.count") do
      post :require_current_nda, params: { id: user.id, reason: "Testing the revised agreement" }
    end

    assert_redirected_to admin_root_path
    assert_predicate user.reload, :current_nda_required_at?
    assert NdaSignature.exists?(legacy.id)
    action = AdminAction.last
    assert_equal "require_current_nda", action.action
    assert_equal NdaDocument::VERSION, action.details["document_version"]
  end

  test "moving to the current NDA requires a reason" do
    assert_no_difference("AdminAction.count") do
      post :require_current_nda, params: { id: users(:one).id }
    end

    assert_not users(:one).reload.current_nda_required_at?
  end

  test "reset removes only the current NDA and leaves an audit trail" do
    user = users(:one)
    current = create_signature(user, signed_at: Time.current)
    legacy = create_legacy_signature(user)

    assert_difference("NdaSignature.count", -1) do
      post :reset_nda, params: { id: user.id, reason: "Needs to accept the revised process" }
    end

    assert_not NdaSignature.exists?(current.id)
    assert NdaSignature.exists?(legacy.id)
    action = AdminAction.last
    assert_equal "reset_nda", action.action
    assert_equal current.id, action.subject_id
    assert_equal user, action.target_user
  end

  test "reset requires a reason" do
    signature = create_signature(users(:one), signed_at: Time.current)

    assert_no_difference("NdaSignature.count") do
      post :reset_nda, params: { id: users(:one).id }
    end
    assert NdaSignature.exists?(signature.id)
  end
  test "fresh Airtable recheck queues a lookup and records the admin" do
    user = users(:one)
    user.update!(airtable_checked_at: Time.current)
    with_airtable do
      assert_enqueued_with(job: ImportAirtableNdaJob, args: ->(args) { args.last == { fresh: true } && LegacyNdaImport.exists?(args.first) }) do
        post :recheck_airtable, params: { id: user.id }
      end
    end
    import = user.legacy_nda_imports.sole
    assert_predicate import, :source_airtable?
    assert_equal "recheck_airtable", AdminAction.last.action
    assert_equal import.id, AdminAction.last.subject_id
    assert_redirected_to admin_root_path
  end

  test "rechecking cannot bypass admin access" do
    session[:user_id] = users(:one).id
    assert_no_enqueued_jobs do
      post :recheck_airtable, params: { id: users(:one).id }
    end
    assert_redirected_to root_path
  end

  test "rechecking refuses existing coverage or a missing verified email" do
    user = users(:one)
    create_legacy_signature(user)
    assert_no_difference("LegacyNdaImport.count") { post :recheck_airtable, params: { id: user.id } }
    user.nda_signatures.destroy_all
    user.update!(verified_email: nil)
    with_airtable do
      assert_no_difference("LegacyNdaImport.count") { post :recheck_airtable, params: { id: user.id } }
    end
  end

  test "links a second account to another member's legacy NDA with an audit trail" do
    owner = users(:one)
    signature = create_legacy_signature(owner)
    second = User.create!(hack_club_identity_id: "ident!hq", slack_id: "U0HQACCOUNT")

    assert_difference([ "NdaSignatureLink.count", "AdminAction.count" ]) do
      post :link_nda, params: { id: second.id, slack_id: " #{owner.slack_id.downcase} ", reason: "Same person, HQ account" }
    end

    assert_redirected_to admin_root_path
    assert_equal signature, second.reportable_nda_signature
    link = second.nda_signature_links.sole
    assert_predicate link, :admin?
    action = AdminAction.last
    assert_equal "link_nda", action.action
    assert_equal second, action.target_user
    assert_equal owner.slack_id, action.details["owner_slack_id"]
  end

  test "linking refuses a missing reason, an unknown or own Slack ID, existing coverage, or no NDA" do
    owner = users(:one)
    second = User.create!(hack_club_identity_id: "ident!hq", slack_id: "U0HQACCOUNT")

    assert_no_difference("NdaSignatureLink.count") do
      post :link_nda, params: { id: second.id, slack_id: owner.slack_id, reason: "No NDA yet" }
      create_legacy_signature(owner)
      post :link_nda, params: { id: second.id, slack_id: owner.slack_id }
      post :link_nda, params: { id: second.id, slack_id: "U0NOBODY000", reason: "Typo" }
      post :link_nda, params: { id: second.id, slack_id: second.slack_id, reason: "Self" }
      post :link_nda, params: { id: owner.id, slack_id: second.slack_id, reason: "Already covered" }
    end

    assert_nil second.reportable_nda_signature
  end

  test "links a second account to another member's current native NDA" do
    owner = users(:one)
    signature = create_signature(owner, signed_at: Time.current)
    second = User.create!(hack_club_identity_id: "ident!hq", slack_id: "U0HQACCOUNT")

    assert_difference("NdaSignatureLink.count") do
      post :link_nda, params: { id: second.id, slack_id: owner.slack_id, reason: "Same person, HQ account" }
    end

    assert_equal signature, second.reportable_nda_signature
    assert_equal "native", AdminAction.last.details["signature_type"]
    assert_equal "Linked #{second.slack_id} to #{owner.slack_id}'s native NDA.", flash[:notice]
  end

  test "unlinking removes the link and records who it pointed at" do
    owner = users(:one)
    signature = create_legacy_signature(owner)
    second = User.create!(hack_club_identity_id: "ident!hq", slack_id: "U0HQACCOUNT")
    signature.nda_signature_links.create!(user: second, proven_via: "challenge")

    assert_no_difference("NdaSignatureLink.count") { post :unlink_nda, params: { id: second.id } }
    assert_difference("NdaSignatureLink.count", -1) do
      post :unlink_nda, params: { id: second.id, reason: "Not the same person" }
    end

    assert_nil second.reportable_nda_signature
    assert NdaSignature.exists?(signature.id)
    action = AdminAction.last
    assert_equal "unlink_nda", action.action
    assert_equal "challenge", action.details["proven_via"]
    assert_equal owner.slack_id, action.details["owner_slack_id"]
  end
end
