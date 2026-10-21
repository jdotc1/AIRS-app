# Development source update — stronger C4 AIRS exchange

This source update adds the AIRS producer/archive and consumer-acknowledgment
admission boundary. It supplies no new downloadable app and makes no new signing,
notarization, installed-app or full paired-integration claim.

- Preserve original audit bytes and bind the selected finding/configuration in a
  distinct two-attachment request archive; retain the legacy manual-v1 export.
- Import strictly validated terminal acknowledgments, correlate exact retained
  request/source/finding identity, and keep unmatched receipts unassociated.
- Retain original request/receipt bytes across sessions, reject conflicting IDs,
  and invalidate cached evidence when file witnesses change.
- Add explicit native commands for bound export, receipt import/review and request
  retention; native interaction acceptance remains pending.
- Include focused protocol/workspace tests and a public wire-contract description.
  Test output roots are portable and optionally controlled by AIRS_TEST_OUTPUT_ROOT.

The original implementation's 12 focused contract tests and one workspace test
passed locally. Their receipts are reused for unchanged behavior. Public-source
portability edits affect only five test output-directory expressions; affected
selector results are recorded in the source-update pull request. No full suite,
sealed source hash, signing/dependency gate, GUI or corpus check is repeated.

## Published app: 0.2.0/build 3

The existing preview remains signed, notarized/stapled, published and installed
within its recorded qualification scope. It consolidates entitlement inspection,
review archives, component comparison, scoped assessments, projects/history,
owned-build policy review and CLZ-v32 bounded analysis.

Accepted B6 observations retain the same 16-function denominator: 11 agreement,
zero inconsistency, five unresolved, three expected gains and 13 otherwise
unchanged findings. These are retained observations, not a new corpus execution.
Known native diagnostics and clean-Mac/older-OS limits remain explicit.

The stronger C4 consumer and paired acknowledgment workflow are not part of that
released binary. Existing release tags/assets are unchanged by this source update.
