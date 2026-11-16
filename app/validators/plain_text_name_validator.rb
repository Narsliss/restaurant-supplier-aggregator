# frozen_string_literal: true

# Rejects names that carry links or HTML: `<`, `>`, `http://`, `https://`, `www.`.
#
# Why: form-spam bots plant links in name fields ("<a href=…>SCAM SERVICE</a>")
# hoping they show up as live links, or travel in our emails. Invitation emails
# put the organization and inviter names in the subject and body. Output is
# already escaped everywhere, so this is defense in depth, not an XSS fix.
#
# Apply it with `if: :<attr>_changed?` so existing rows are never re-checked:
# a legacy name can't make an unrelated save fail. Bare domains ("myxa.cc") are
# deliberately NOT matched; too many real names contain a dot.
#
#   validates :name, plain_text_name: true, if: :name_changed?
#
# See docs/signup-bot-guard.md.
class PlainTextNameValidator < ActiveModel::EachValidator
  PATTERN = %r{[<>]|https?://|www\.}i
  MESSAGE = "can't contain links or the < > characters"

  def validate_each(record, attribute, value)
    return if value.blank?
    return unless value.to_s.match?(PATTERN)

    record.errors.add(attribute, options[:message] || MESSAGE)
  end
end
