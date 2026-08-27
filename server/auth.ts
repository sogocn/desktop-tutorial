import jwt from 'jsonwebtoken'
import crypto from 'node:crypto'

const SECRET = process.env.JWT_SECRET ?? 'dev-insecure-change-me'
const ISSUER = 'familyquest-server'

/** 签发长期令牌：本应用没有密码，loginKey 本身就是凭证，所以令牌可以长命。 */
export function signToken(sub: string): string {
  return jwt.sign({ sub, role: 'authenticated' }, SECRET, {
    issuer: ISSUER,
    expiresIn: '365d',
  })
}

export function verifyToken(token: string): { sub: string } {
  const p = jwt.verify(token, SECRET, { issuer: ISSUER }) as jwt.JwtPayload
  if (!p.sub) throw new Error('令牌缺少 sub')
  return { sub: String(p.sub) }
}

/** 登录密钥的不可逆哈希，落库只存哈希。 */
export function hashKey(key: string): string {
  return crypto.createHash('sha256').update(key).digest('hex')
}
