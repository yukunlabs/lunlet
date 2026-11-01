## User outcome

Describe the behavior this changes and link the related Issue. Cite the confirmed story and criterion IDs in `docs/requirements.md`. If the story is still proposed, keep the PR as a proposal until the owner confirms it.

## Changes and evidence

- Behavior and affected source:
- Focused tests and result:
- Full suite, traceability and site checks (as applicable):
- Native, provider or signed-update checks actually performed:
- Acceptance gaps and release impact:

## Review checks

- [ ] The change matches confirmed criteria and keeps account, session and message identity separate.
- [ ] No real credentials, personal conversations, raw callbacks or unredacted logs are included.
- [ ] New dependencies or assets have reviewed license and attribution terms.
- [ ] Documentation and UI copy describe current capability without claiming synthetic tests are live acceptance.
- [ ] Cancellation, binding, authorization and cleanup boundaries remain covered where relevant.
- [ ] The product page is in step: a story this change confirms declares its page section and is presented there, interface changes come with re-rendered stills (`scripts/render-site-assets.sh`), and `python3 scripts/check_site_assets.py` passes.
