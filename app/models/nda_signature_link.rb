# A second Hack Club account covered by a legacy signature another account holds, because it proved
# control of the same address the signature was settled on (see LegacyNda::Link), or because an admin
# bound the two accounts by hand, which AdminAction records with a reason.
class NdaSignatureLink < ApplicationRecord
  belongs_to :nda_signature
  belongs_to :user
  belongs_to :legacy_nda_import, optional: true

  enum :proven_via, { account_email: "account_email", challenge: "challenge", admin: "admin" }, validate: true
end
