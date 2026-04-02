# Git & Commit Standards

> **Load when:** Creating branches, committing, or managing Git workflow

---

## Branch Naming

### Ruleset Regex

All branches **must** match the following pattern enforced by the GitHub repository ruleset:

```
^(epic|feature|story|release|task|bug|poc)\/[A-Za-z0-9]+(-[A-Za-z0-9]+)*$
```

### Allowed Types

| Type | When to use |
|---------|-------------|
| `epic` | Large multi-sprint initiatives |
| `feature` | New functionality |
| `story` | User story scoped work |
| `release` | Release preparation branches |
| `task` | Non-feature engineering tasks |
| `bug` | Bug fixes |
| `poc` | Proof-of-concept / experimental work |

### Format Rules

- **Must** use one of the 7 allowed type prefixes followed by `/`
- **Must** contain only alphanumeric characters (`A-Z`, `a-z`, `0-9`) and hyphens (`-`) after the prefix separator
- **Must not** contain spaces, underscores, or dots
- **Must** use hyphens only as segment separators (not at the start or end of the description)
- **Must** start and end the description portion with an alphanumeric character
- **Should** include the Jira ticket number where one exists (e.g. `PROJ-1234`)

### Valid Examples

```
feature/PROJ-1234
feature/PROJ-1234-add-payment-gateway
bug/PROJ-5678-fix-null-reference-checkout
task/update-nuget-dependencies
story/PROJ-9012-user-can-reset-password
release/2026-Q1
poc/blazor-component-architecture
epic/PROJ-100-multi-tenant-support
```

### Invalid Examples (rejected by ruleset)

```
Feature/PROJ-1234-add-payment          # type prefix must be lowercase
feature/PROJ_1234_add_payment          # underscores not allowed
feature/add payment feature            # spaces not allowed
hotfix/PROJ-1234-urgent-fix            # 'hotfix' is not an allowed type
feature/-starts-with-hyphen            # description must start with alphanumeric
feature/ends-with-hyphen-              # description must end with alphanumeric
feature/has.dot.separators             # dots not allowed
feature/                               # empty description — at least one alphanumeric segment required
```

---

## Commit Messages

### Format

```
type(scope): description [TICKET#]
```

### Rules

- **Use imperative mood** — write "Add feature" not "Added feature" or "Adds feature"
- **Include scope** — omit only when the change is truly cross-cutting and no single scope applies
- **No trailing periods** on the subject line
- **Subject line limit** — 72 characters maximum
- **Reference the Jira ticket** at the end of the subject line where one exists

### Allowed Types

`feat` · `fix` · `docs` · `style` · `refactor` · `test` · `chore` · `perf` · `ci` · `revert`

### Valid Examples

```
feat(checkout): add payment gateway integration [PROJ-1234]
fix(auth): resolve null reference on token refresh [PROJ-5678]
docs(standards): expand git-commits with full branch naming rules
refactor(dal): migrate legacy system calls to new DAL repository [PROJ-9012]
chore(deps): update NuGet packages to latest stable versions
```

---

## General Git Hygiene

- **No merge commits** — always rebase onto the target branch before opening or updating a PR
- **Squash fixup commits** before marking a PR as ready for review; keep history clean and intentional
- **One logical change per commit** where practical — avoid bundling unrelated changes in a single commit
- **Never commit secrets, tokens, or credentials** — use environment variables or secret managers; rotate immediately if accidentally committed
