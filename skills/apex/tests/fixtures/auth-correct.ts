// Fixture: Controller with correct ownership validation
// Expected: PASS on AUTH-01 (ownership check on primary query)

import { HttpContext } from '@adonisjs/core/http'

export default class ProjectsController {
  async show({ params, auth }: HttpContext) {
    const userId = auth.user!.id

    const project = await Project.query()
      .where('id', params.id)
      .where('userId', userId)
      .firstOrFail()

    return { data: project }
  }

  async update({ params, auth, request }: HttpContext) {
    const userId = auth.user!.id
    const payload = request.only(['name', 'description'])

    const project = await Project.query()
      .where('id', params.id)
      .where('userId', userId)
      .firstOrFail()

    project.merge(payload)
    await project.save()

    return { data: project }
  }
}
