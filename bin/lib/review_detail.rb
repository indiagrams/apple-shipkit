# frozen_string_literal: true

# Bootstrap::ReviewDetail — guards the App Review detail record against a field
# deliver rewrites from input it was never given.
#
# THE BUG THIS EXISTS FOR
#
# `deliver`'s `review_information()` (deliver/lib/deliver/upload_metadata.rb)
# strips every review field and omits the empty ones from its
# `appStoreReviewDetail` PATCH — which is correct, and is exactly what the
# Fastfile's `" "` sentinel relies on to keep placeholder contact details from
# reaching Apple. But it then finishes with:
#
#     if !attributes["demo_account_name"].to_s.empty? &&
#        !attributes["demo_account_password"].to_s.empty?
#       attributes["demo_account_required"] = true
#     else
#       attributes["demo_account_required"] = false   # <-- writes, never omits
#     end
#
# The `else` branch **writes** rather than omits. So when a fork has no
# `APP_REVIEW_DEMO_USER` / `APP_REVIEW_DEMO_PASSWORD` configured, the sentinel
# empties both, deliver omits them from the PATCH — leaving App Store Connect's
# stored credentials untouched, as intended — and then sets
# `demo_account_required = false` on top of those retained credentials.
#
# The result is a record that contradicts itself: a demo account is present and
# populated, but flagged as not required. Nobody chose that. The flag was
# derived from values the caller deliberately declined to send.
#
# Observed on indiagrams/tunnelless: `0.1.0` was approved with
# `demoAccountRequired: true`; the first `make submit` for `0.1.1` produced
# `false` on both platforms while the inherited credentials stayed in place. It
# is invisible from the exit code and from deliver's log — only a read-back of
# the review detail shows it.
#
# THE RULE
#
# A field must not change because of input that was not supplied. So: snapshot
# the review detail before the lanes run, read it back after, and restore the
# flag **only** when deliver changed it without changing the credentials it
# derives from. If the credentials genuinely changed, deliver's derivation is
# honest and is left alone.
module Bootstrap
  module ReviewDetail
    # Decide whether `demo_account_required` must be put back, and to what.
    #
    # `before` / `after` are hashes with :required, :name, :password. Returns
    # the value to restore, or nil to leave the record as deliver left it.
    #
    # Pure, so the decision is testable without touching ASC.
    def self.flag_to_restore(before:, after:)
      return nil if before.nil? || after.nil?

      # Credentials deliver actually rewrote → its derivation reflects real
      # input, so it stands even if that flipped the flag.
      return nil unless creds_equal?(before, after)

      # Nothing to undo.
      return nil if before[:required] == after[:required]

      before[:required]
    end

    def self.creds_equal?(before, after)
      before[:name].to_s == after[:name].to_s &&
        before[:password].to_s == after[:password].to_s
    end

    # Normalize a Spaceship::ConnectAPI::AppStoreReviewDetail (or nil) into the
    # plain hash `flag_to_restore` compares. Keeps the ASC object out of the
    # decision logic so the logic stays testable.
    def self.snapshot(detail)
      return nil if detail.nil?

      {
        required: detail.demo_account_required,
        name: detail.demo_account_name.to_s,
        password: detail.demo_account_password.to_s
      }
    end
  end
end
