// Fixture: Financial route (Stripe/credit) without rate limit middleware
// Expected: FAIL on RATE-01 (missing rateLimitFinancial on billing routes)

import router from '@adonisjs/core/services/router'
import { middleware } from '#start/kernel'

router.group(() => {
  router.post('/checkout', [SubscriptionController, 'checkout'])
  router.post('/cancel', [SubscriptionController, 'cancel'])
  router.post('/resume', [SubscriptionController, 'resume'])
}).prefix('/api/billing').use([
  middleware.auth(),
  middleware.rateLimit(),
])

router.group(() => {
  router.post('/credits/purchase', [CreditsController, 'purchase'])
  router.post('/generate', [CanvasController, 'generate'])
}).prefix('/api/credits').use([
  middleware.auth(),
])
