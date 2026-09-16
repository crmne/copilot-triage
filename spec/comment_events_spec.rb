# frozen_string_literal: true

require_relative '../lib/assessment'

RSpec.describe 'Comment assessments' do
  let(:environment) do
    { 'GITHUB_REPOSITORY' => 'crmne/example', 'TRIAGE_NUMBER' => '123', 'TRIAGE_CONFIG' => 'triage.yml',
      'TRIAGE_KIND' => kind, 'GITHUB_EVENT_NAME' => 'issue_comment', 'GITHUB_EVENT_PATH' => 'event.json' }
  end
  let(:kind) { 'issue' }
  let(:assessment) { IssueAssessment.new(environment) }
  let(:comment) do
    { 'id' => 'comment-id', 'createdAt' => '2026-09-15T12:00:00Z', 'body' => 'Version 1.2.3 now crashes.',
      'author' => { '__typename' => 'User', 'login' => 'reporter' }, 'authorAssociation' => 'NONE' }
  end
  let(:event) do
    { 'action' => 'created', 'sender' => { 'login' => 'reporter', 'type' => 'User' },
      'issue' => { 'number' => 123, 'state' => 'open' },
      'comment' => { 'node_id' => 'comment-id', 'user' => { 'login' => 'reporter', 'type' => 'User' },
                     'author_association' => 'NONE' } }
  end
  let(:item) do
    { 'id' => 'report-id', 'title' => 'A question', 'body' => 'How do I use this?', 'closed' => false,
      'author' => { 'login' => 'reporter' }, 'comments' => { 'nodes' => [comment] } }
  end
  let(:decision) { JSON.generate(labels: [], reply: 'provider', files: []) }

  before do
    allow(assessment).to receive(:event) { event }
    allow(assessment).to receive_messages(read_report: [item, []], ask_copilot: decision)
    allow(assessment).to receive(:sleep)
    allow(assessment).to receive(:puts)
    allow(assessment).to receive(:mutate)
  end

  it 'waits for nearby comments before reading the report and assessing the human follow-up' do
    expect(assessment).to receive(:sleep).with(10).ordered
    expect(assessment).to receive(:read_report).ordered.and_return([item, []])
    expect(assessment).to receive(:ask_copilot).with(include('Version 1.2.3')).ordered.and_return(decision)
    expect(assessment).to receive(:read_report).ordered.and_return([item, []])

    assessment.run

    expect(assessment).to have_received(:mutate).with(
      'addComment', subjectId: 'report-id', body: start_with("Which provider are you using?\n\n")
    )
  end

  it 'does not turn fresh measurements into another diagnostic questionnaire' do
    comment['body'] = 'CPU usage is now 98% focused and 96% unfocused.'
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: 'Which operating system are you using?')
    )

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'also suppresses configured clarification replies on measurement-only updates' do
    comment['body'] = 'CPU usage is now 98% focused and 96% unfocused.'

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
  end

  it 'allows a necessary clarification when explicitly asked to reassess' do
    comment['body'] = '/triage'
    event['comment']['body'] = '/triage'

    assessment.run

    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id',
                                                                    body: start_with('Which provider are you using?'))
  end

  {
    'pull request comments' => ->(e) { e['issue']['pull_request'] = { 'url' => 'a pull request' } },
    'bot comments' => ->(e) { e['comment']['user']['type'] = 'Bot' },
    'bot senders' => ->(e) { e['sender']['type'] = 'Bot' },
    'closed issues' => ->(e) { e['issue']['state'] = 'closed' },
    'closed discussions' => ->(e) { e['discussion'] = { 'closed' => true } },
    'edited comments' => ->(e) { e['action'] = 'edited' },
    'owner comments' => ->(e) { e['comment']['author_association'] = 'OWNER' },
    'member comments' => ->(e) { e['comment']['author_association'] = 'MEMBER' },
    'collaborator comments' => ->(e) { e['comment']['author_association'] = 'COLLABORATOR' }
  }.each do |name, change|
    it "skips #{name} before waiting, fetching GitHub, or calling the model" do
      change.call(event)

      assessment.run

      expect(assessment).not_to have_received(:sleep)
      expect(assessment).not_to have_received(:read_report)
      expect(assessment).not_to have_received(:ask_copilot)
      expect(assessment).not_to have_received(:mutate)
    end
  end

  it 'skips an older event when another comment arrived during the delay' do
    item['comments']['nodes'] << comment.merge('id' => 'newer-comment', 'body' => 'Here are the logs.')

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).not_to have_received(:mutate)
  end

  it 'does not assess a deleted comment' do
    item['comments']['nodes'].clear

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
  end

  it 'skips an issue closed after the event even in preview mode' do
    item['closed'] = true
    environment['TRIAGE_DRY_RUN'] = 'true'

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
  end

  it 'does not repost a clarification already present in the recent conversation' do
    item['comments']['nodes'].unshift(comment.merge('id' => 'bot-comment',
                                                    'body' => 'Which provider are you using?'))

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
    expect(assessment).to have_received(:mutate).with('addReaction', anything)
  end

  it 'reads the event from the Actions event file' do
    File.write('event.json', JSON.generate(event))
    allow(assessment).to receive(:event).and_call_original

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
  end

  [
    'Can someone please disable this copilot bot that is spamming the thread?',
    'Please stop the triage bot from replying.',
    'The Copilot bot should be disabled.'
  ].each do |body|
    it "does not answer a request to stop the bot: #{body}" do
      comment['body'] = body

      assessment.run

      expect(assessment).not_to have_received(:ask_copilot)
      expect(assessment).not_to have_received(:mutate)
    end
  end

  it 'continues to respect a stop request after the reporter posts another update' do
    item['comments']['nodes'].unshift(comment.merge('id' => 'stop-request',
                                                    'body' => 'Please disable the Copilot bot.'))
    comment['body'] = 'After another restart it is still using 90% CPU idle.'

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
    expect(assessment).not_to have_received(:mutate)
  end

  it 'ignores bot-stop wording in quoted examples and code' do
    comment['body'] = "> Please disable the Copilot bot.\n`disable copilot`\n```\nstop copilot\n```\nVersion 1.2.3"

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
  end

  it 'still sees a stop request after a quoted line' do
    comment['body'] = "> A useful next check is whether restarting helps.\nPlease disable Copilot."

    assessment.run

    expect(assessment).not_to have_received(:ask_copilot)
  end

  it 'does not treat disabling an application feature as a request to stop triage' do
    comment['body'] = 'How do I disable animations?'

    assessment.run

    expect(assessment).to have_received(:ask_copilot).once
  end

  it 'suppresses a reworded earlier question even when the attribution changes' do
    previous = "Does restarting the app pick up the system theme?\n\n_Generated by [Copilot Triage](old)._"
    item['comments']['nodes'].unshift(
      comment.merge('id' => 'bot-comment', 'author' => { '__typename' => 'Bot' }, 'body' => previous)
    )
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [],
                    comment: 'Does the app pick up the system theme after restarting?')
    )

    assessment.run

    expect(assessment).not_to have_received(:mutate).with('addComment', anything)
    expect(assessment).to have_received(:mutate).with('addReaction', anything)
  end

  it 'shows the suppressed decision in previews as well as in published runs' do
    environment['TRIAGE_DRY_RUN'] = 'true'
    item['comments']['nodes'].unshift(comment.merge('id' => 'bot-comment',
                                                    'body' => 'Which provider are you using?'))

    assessment.run

    expect(assessment).to have_received(:puts).with(include('"reply":null'))
    expect(assessment).not_to have_received(:puts).with(include('_Generated by'))
  end

  it 'allows a similar question about a different version' do
    item['comments']['nodes'].unshift(comment.merge('id' => 'bot-comment',
                                                    'body' => 'Does restarting the app fix this in version 1.2.3?'))
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: 'Does restarting the app fix this in version 1.2.4?')
    )

    assessment.run

    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id', body: include('1.2.4?'))
  end

  it 'preserves a new diagnostic command even with otherwise identical wording' do
    item['comments']['nodes'].unshift(comment.merge('id' => 'bot-comment',
                                                    'body' => 'What output do you get from `app --version`?'))
    allow(assessment).to receive(:ask_copilot).and_return(
      JSON.generate(labels: [], reply: nil, files: [], comment: 'What output do you get from `app --help`?')
    )

    assessment.run

    expect(assessment).to have_received(:mutate).with('addComment', subjectId: 'report-id', body: include('app --help'))
  end

  context 'with a reply to an older discussion comment' do
    let(:kind) { 'discussion' }
    let(:parent) do
      comment.merge('id' => 'parent-id', 'body' => 'Which version?', 'replies' => { 'nodes' => [comment] })
    end

    before do
      environment['TRIAGE_KIND'] = 'discussion'
      environment['GITHUB_EVENT_NAME'] = 'discussion_comment'
      event.delete('issue')
      event['discussion'] = { 'number' => 123, 'closed' => false }
      allow(assessment).to receive(:read_report).and_call_original
      allow(assessment).to receive(:github) do |_endpoint, **payload|
        if payload.fetch(:variables).key?(:id)
          { 'data' => { 'node' => comment.merge('discussion' => { 'id' => 'report-id' }, 'replyTo' => parent) } }
        else
          { 'data' => { 'repository' => { 'discussion' => Marshal.load(Marshal.dump(item)),
                                          'labels' => { 'nodes' => [] } } } }
        end
      end
    end

    it 'reads the parent and recent replies even outside the latest five top-level comments' do
      item['comments']['nodes'] = [comment.merge('id' => 'unrelated-id', 'body' => 'An unrelated thread')]

      assessment.run

      expect(assessment).to have_received(:ask_copilot).with(include('Which version?', 'Version 1.2.3'))
      expect(assessment).not_to have_received(:ask_copilot).with(include('An unrelated thread'))
      expect(assessment).to have_received(:mutate).with(
        'addDiscussionComment', discussionId: 'report-id', replyToId: 'parent-id',
                                body: start_with("Which provider are you using?\n\n")
      )
    end

    it 'skips superseded replies without spending credits' do
      parent['replies']['nodes'] << comment.merge('id' => 'newer-id', 'body' => 'And the provider is OpenAI.')

      assessment.run

      expect(assessment).not_to have_received(:ask_copilot)
      expect(assessment).not_to have_received(:mutate)
    end

    it 'rereads the thread and discards an answer if a reply arrives during inference' do
      allow(assessment).to receive(:ask_copilot) do
        parent['replies']['nodes'] = [comment.merge('id' => 'newer-id', 'body' => 'Solved!')]
        decision
      end

      assessment.run

      expect(assessment).to have_received(:ask_copilot).once
      expect(assessment).not_to have_received(:mutate)
    end

    it 'skips a deleted discussion comment' do
      allow(assessment).to receive(:github).with('graphql', query: anything, variables: { id: 'comment-id' })
                                           .and_return('data' => { 'node' => nil })

      assessment.run

      expect(assessment).not_to have_received(:ask_copilot)
    end

    it 'respects a stop request in the parent of an older discussion thread' do
      parent['body'] = 'Please disable the Copilot bot.'

      assessment.run

      expect(assessment).not_to have_received(:ask_copilot)
      expect(assessment).not_to have_received(:mutate)
    end

    it 'replies within the thread when the event is a top-level discussion comment' do
      allow(assessment).to receive(:github).with('graphql', query: anything, variables: { id: 'comment-id' })
                                           .and_return('data' => { 'node' => comment.merge(
                                             'discussion' => { 'id' => 'report-id' }, 'replyTo' => nil,
                                             'replies' => { 'nodes' => [] }
                                           ) })

      assessment.run

      expect(assessment).to have_received(:mutate).with(
        'addDiscussionComment', discussionId: 'report-id', replyToId: 'comment-id',
                                body: start_with("Which provider are you using?\n\n")
      )
    end
  end
end
