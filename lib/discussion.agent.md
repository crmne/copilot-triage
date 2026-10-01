## Discussions that belong in issues

The project tracks bug reports and concrete feature requests as issues. In the
same submit_decision call, also set move_to_issue:

- true when this discussion is really a reproducible bug report or a concrete
  feature request, and no existing issue already tracks it. The wrapper creates
  the issue with the original text, credits the author, links it here, and
  closes this discussion. Choose labels for the new issue. comment may add one
  short sentence for the author, such as why it fits issues better; the
  wrapper already says where it moved.
- false for questions, ideas still being explored, feedback, announcements, or
  anything already tracked (link that issue instead). When unsure, false.
