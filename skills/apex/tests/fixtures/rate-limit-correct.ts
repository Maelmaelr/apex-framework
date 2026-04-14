// Fixture: Financial route with rate limit middleware applied
// Expected: PASS on RATE-01 (rate limiting on financial routes)

import router from '@adonisjs/core/services/router'
import { middleware } from '#start/kernel'

router.group(() => {
  router.post('/checkout', [SubscriptionController, 'checkout'])
  router.post('/cancel', [SubscriptionController, 'cancel'])
  router.post('/resume', [SubscriptionController, 'resume'])
  router.post('/credits/purchase', [CreditsController, 'purchase'])
}).prefix('/api/billing').use([
  middleware.auth(),
  middleware.rateLimitFinancial(),
])

router.group(() => {
  router.post('/generate', [CanvasController, 'generate'])
}).prefix('/api/canvas').use([
  middleware.auth(),
  middleware.rateLimitFinancial(),
])
