class Admin::UsersController < ApplicationController
  before_action :require_admin

  def recheck_airtable
    user = User.find(params[:id])
    return redirect_to admin_root_path, alert: "That member already has NDA coverage." if user.reportable_nda_signature
    return redirect_to admin_root_path, alert: "Airtable is not configured." unless AirtableClient.configured?
    return redirect_to admin_root_path, alert: "That member has no verified account email." if user.verified_email.blank?

    import = user.transaction do
      pending = user.legacy_nda_imports.create!(source: "airtable", ip_address: request.remote_ip)
      AdminAction.record!(admin: current_user, target_user: user, action: "recheck_airtable", subject: pending)
      pending
    end
    ImportAirtableNdaJob.perform_later(import.id, fresh: true)
    redirect_to admin_root_path, notice: "Queued a fresh Airtable lookup for #{user.slack_id}. The member can check their import page for the result."
  end

  def require_current_nda
    user = User.find(params[:id])
    return redirect_to admin_root_path, alert: "That member already has the current NDA." if user.signature_for_current_version

    reason = params[:reason].to_s.strip
    return redirect_to admin_root_path, alert: "A reason is required." if reason.blank?

    user.transaction do
      user.update!(current_nda_required_at: Time.current)
      AdminAction.record!(admin: current_user, target_user: user, action: "require_current_nda", subject: user,
        reason:, details: { "document_version" => NdaDocument::VERSION })
    end
    redirect_to admin_root_path, notice: "Moved #{user.slack_id} to the current NDA flow. Their prior NDA remains on file."
  end

  def reset_nda
    user = User.includes(:nda_signatures).find(params[:id])
    signature = user.signature_for_current_version
    return redirect_to admin_root_path, alert: "That member does not have a current NDA to reset." unless signature

    reason = params[:reason].to_s.strip
    return redirect_to admin_root_path, alert: "A reason is required." if reason.blank?

    signature.transaction do
      AdminAction.record!(admin: current_user, target_user: user, action: "reset_nda", subject: signature,
        reason:, details: { "document_version" => signature.document_version })
      signature.destroy!
    end
    redirect_to admin_root_path, notice: "Reset #{user.slack_id}'s current NDA. They can sign again."
  end

  def link_nda
    user = User.find(params[:id])
    return redirect_to admin_root_path, alert: "That member already has NDA coverage." if user.reportable_nda_signature

    reason = params[:reason].to_s.strip
    return redirect_to admin_root_path, alert: "A reason is required." if reason.blank?

    owner = User.find_by(slack_id: params[:slack_id].to_s.strip.upcase)
    return redirect_to admin_root_path, alert: "No member has that Slack ID." unless owner
    return redirect_to admin_root_path, alert: "Choose a different member's Slack ID." if owner == user

    signature = owner.reportable_nda_signature
    return redirect_to admin_root_path, alert: "#{owner.slack_id} has no approved NDA to share." unless signature

    user.transaction do
      link = signature.nda_signature_links.create!(user:, proven_via: "admin")
      AdminAction.record!(admin: current_user, target_user: user, action: "link_nda", subject: link, reason:,
        details: { "nda_signature_id" => signature.id, "owner_slack_id" => signature.user.slack_id,
                   "signature_type" => signature.signature_type })
    end
    redirect_to admin_root_path, notice: "Linked #{user.slack_id} to #{signature.user.slack_id}'s #{signature.signature_type} NDA."
  end

  def unlink_nda
    user = User.find(params[:id])
    link = user.nda_signature_links.includes(nda_signature: :user).find_by(nda_signature: user.reportable_nda_signature)
    return redirect_to admin_root_path, alert: "That member is not covered by a linked NDA." unless link

    reason = params[:reason].to_s.strip
    return redirect_to admin_root_path, alert: "A reason is required." if reason.blank?

    link.transaction do
      AdminAction.record!(admin: current_user, target_user: user, action: "unlink_nda", subject: link, reason:,
        details: { "nda_signature_id" => link.nda_signature_id, "owner_slack_id" => link.nda_signature.user.slack_id,
                   "proven_via" => link.proven_via })
      link.destroy!
    end
    redirect_to admin_root_path, notice: "Removed #{user.slack_id}'s link to #{link.nda_signature.user.slack_id}'s NDA."
  end
end
