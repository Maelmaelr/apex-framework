// Fixture: Validator with .optional() but missing .nullable() on clearable field
// Expected: FAIL on INPUT-01 (nullable gap on clearable fields)

import vine from '@vinejs/vine'

export const updateSettingsValidator = vine.compile(
  vine.object({
    // Correct: non-clearable field, optional is sufficient
    displayName: vine.string().maxLength(128).optional(),

    // BUG: privacyLevel can be explicitly cleared (set to null)
    // but .optional() alone rejects null values -- needs .nullable().optional()
    privacyLevel: vine.string().optional(),

    // Correct: clearable field with nullable chained
    defaultHashtags: vine.string().nullable().optional(),

    // BUG: same issue -- notifySubscribers is a boolean toggle
    // that users can explicitly clear, but null is rejected
    notifySubscribers: vine.boolean().optional(),
  })
)
