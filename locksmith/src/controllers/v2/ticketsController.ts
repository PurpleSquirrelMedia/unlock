import { Request, Response } from 'express'
import Dispatcher from '../../fulfillment/dispatcher'
import { notifyNewKeyToWedlocks } from '../../operations/wedlocksOperations'
import Normalizer from '../../utils/normalizer'
import { Web3Service } from '@unlock-protocol/unlock-js'
import logger from '../../logger'
import { generateQrCode } from '../../utils/qrcode'
import { KeyMetadata } from '../../models/keyMetadata'

export class TicketsController {
  public web3Service: Web3Service
  constructor({ web3Service }: { web3Service: Web3Service }) {
    this.web3Service = web3Service
  }

  /**
   * API to generate signatures that prove validity of a token
   * @param request
   * @param response
   * @returns
   */
  async sign(request: Request, response: Response) {
    const lockAddress = Normalizer.ethereumAddress(request.params.lockAddress)
    const network = Number(request.params.network)
    const tokenId = request.params.keyId

    const dispatcher = new Dispatcher()
    const [payload, signature] = await dispatcher.signToken(
      network,
      lockAddress,
      tokenId
    )
    response.status(200).send({ payload, signature })
  }
  /**
   * This will mark a ticket as check-in, this operation is only allowed for a lock verifier of a lock manager
   * @param {Request} request
   * @param {Response} response
   * @return
   */
  async markTicketAsCheckIn(request: Request, response: Response) {
    try {
      const lockAddress = Normalizer.ethereumAddress(request.params.lockAddress)
      const network = Number(request.params.network)
      const id = request.params.keyId.toLowerCase()

      const keyMetadata = await KeyMetadata.findOne({
        where: {
          id,
          address: lockAddress,
        },
      })

      const data = keyMetadata?.data as unknown as {
        metadata: { checkedInAt: number }
      }

      const isCheckedIn = data?.metadata?.checkedInAt

      if (isCheckedIn) {
        return response.status(409).send({
          error: 'Ticket already checked in',
        })
      }

      await KeyMetadata.upsert(
        {
          id,
          chain: network,
          address: lockAddress,
          data: {
            ...data,
            metadata: {
              ...data?.metadata,
              checkedInAt: new Date().getTime(),
            },
          },
        },
        {
          returning: true,
        }
      )
      return response.status(202).send({
        message: 'Ticket checked in',
      })
    } catch (error) {
      logger.error(error.message)
      return response.status(500).send({
        error: 'Could not mark ticket as checked in',
      })
    }
  }

  /**
   * API call to send an QR code by email. This can only be called by a lock manager
   * @param request
   * @param response
   * @returns
   */
  async sendEmail(request: Request, response: Response) {
    try {
      const lockAddress = Normalizer.ethereumAddress(request.params.lockAddress)
      const network = Number(request.params.network)
      const keyId = request.params.keyId.toLowerCase()

      const keyOwner = await this.web3Service.ownerOf(
        lockAddress,
        keyId,
        network
      )
      await notifyNewKeyToWedlocks(
        {
          keyId,
          lock: {
            address: lockAddress,
          },
          owner: {
            address: keyOwner,
          },
        },
        network,
        true
      )
      return response.status(200).send({
        sent: true,
      })
    } catch (err) {
      logger.error(err.message)
      return response.sendStatus(500)
    }
  }

  /**
   * Function that serves a QR code.
   * It can only be called by a lock manager (otherwise anyone can create a valid QR code that will be used to check-in!)
   * @param request
   * @param response
   * @returns
   */
  async getQrCode(request: Request, response: Response) {
    try {
      const lockAddress = Normalizer.ethereumAddress(request.params.lockAddress)
      const network = Number(request.params.network)
      const tokenId = request.params.keyId.toLowerCase()

      const qrCode = (
        await generateQrCode({
          network,
          lockAddress,
          tokenId,
        })
      ).replace('data:image/gif;base64,', '')
      const img = Buffer.from(qrCode, 'base64')

      response.writeHead(200, {
        'Content-Type': 'image/gif',
      })
      return response.end(img)
    } catch (err) {
      logger.error(err)
      return response.sendStatus(500).send({
        message: 'Failed to generate QR code',
      })
    }
  }
}
