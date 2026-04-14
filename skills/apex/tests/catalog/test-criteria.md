# Regression Test Criteria Catalog v1.0

## Metadata

- created: 2026-03-30
- criteria-count: 3
- sources: CLAUDE.md Security-Sensitive, AdonisJS Gotchas
- format: deterministic pre-filters for target-x-criterion matrix generation
- pre-filter-syntax: grep -E (ERE)
- target-syntax: shell glob (compatible with glob.glob() and find)
- project-root: ~/.claude/skills/apex/tests/fixtures/ (fixture files for regression testing)


# Ownership Validation (AUTH)

## AUTH-01: Primary query includes userId scoping
- description: Controllers that query resources by ID must include `.where('userId', userId)` on the primary query. Querying by `id` or `accountId` alone allows any authenticated user to access or modify another user's resources (IDOR vulnerability).
- targets: `*.ts`
- pre-filter: `\.where\(|\.query\(`
- property: Every .query().where('id', ...) chain also includes .where('userId', userId)
- pass: All primary resource queries scope by userId
- fail: A query fetches by id/accountId without userId scoping
- severity: critical
- source: CLAUDE.md Security-Sensitive (IDOR cross-resource ownership gap)


# Rate Limiting (RATE)

## RATE-01: Financial routes use rateLimitFinancial middleware
- description: Routes that call Stripe for billing actions or consume credits must use rateLimitFinancial middleware, not standard rateLimit. Standard rate limiting has higher thresholds unsuitable for financial operations.
- targets: `*.ts`
- pre-filter: `checkout|purchase|billing|credits|rateLimitFinancial|rateLimit\(`
- property: All route groups containing financial endpoints use rateLimitFinancial()
- pass: Financial route groups use middleware.rateLimitFinancial()
- fail: Financial route uses middleware.rateLimit() or has no rate limiting
- severity: high
- source: CLAUDE.md Security-Sensitive (financial rate limiting)


# Input Validation (INPUT)

## INPUT-01: Clearable fields chain .nullable().optional()
- description: VineJS validators for fields that can be explicitly cleared (set to null) must chain .nullable().optional(), not just .optional(). Using .optional() alone silently rejects null values, making it impossible for users to clear previously set fields.
- targets: `*.ts`
- pre-filter: `\.optional\(\)|\.nullable\(\)`
- property: Fields that represent clearable settings use .nullable().optional()
- pass: All clearable fields chain .nullable().optional()
- fail: A clearable field uses .optional() without .nullable()
- severity: medium
- source: CLAUDE.md AdonisJS Gotchas (VineJS nullable fields)
