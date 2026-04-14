// Fixture: Controller querying by account_id without userId scoping
// Expected: FAIL on AUTH-01 (missing ownership validation -- IDOR vulnerability)

import { HttpContext } from '@adonisjs/core/http'

export default class PostsController {
  async publish({ params, auth }: HttpContext) {
    const userId = auth.user!.id

    // BUG: fetches account by ID alone -- any authenticated user
    // can post to another user's social media account
    const account = await TiktokAccount.query()
      .where('id', params.accountId)
      .firstOrFail()

    const tokens = await OAuthToken.query()
      .where('accountId', account.id)
      .firstOrFail()

    await this.publishToTiktok(tokens.accessToken, params.videoId)

    return { success: true }
  }
}
