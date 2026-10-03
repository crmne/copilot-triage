# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

# A repository's triage policy, on top of an account-wide one it extends:
#
#   extends: crmne/github-automation:triage/account.yml
#   labels:
#     bug: A reproducible problem.
#
# The repository's own settings win; sections such as board or pull_requests
# merge key by key. An account policy that cannot be read is reported and
# skipped, so triage keeps running on the repository's own policy.
module TriagePolicy
  module_function

  def load(path, token: nil)
    policy = YAML.safe_load_file(path)
    return policy unless policy.is_a?(Hash) && policy['extends']

    base = fetch(policy['extends'], token)
    base ? merge(base, policy.except('extends')) : policy.except('extends')
  end

  def fetch(reference, token)
    repository, file = reference.split(':', 2)
    path = "repos/#{repository}/contents/#{file || '.github/triage.yml'}"
    environment = token ? { 'GH_TOKEN' => token, 'GITHUB_TOKEN' => nil } : {}
    output, _errors, status = Open3.capture3(environment, 'gh', 'api', path, '-H', 'Accept: application/vnd.github.raw')
    base = YAML.safe_load(output) if status.success?
    return base if base.is_a?(Hash)

    warn "Account policy #{reference} could not be read; using the repository's own."
    nil
  rescue Psych::Exception
    warn "Account policy #{reference} is not valid YAML; using the repository's own."
    nil
  end

  def merge(base, local)
    base.merge(local) { |_key, ours, theirs| ours.is_a?(Hash) && theirs.is_a?(Hash) ? merge(ours, theirs) : theirs }
  end
end
