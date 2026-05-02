import Foundation

struct AppServerResponse<Result: Decodable>: Decodable {
  let id: Int
  let result: Result?
  let error: AppServerErrorPayload?
}

struct AppServerErrorPayload: Decodable, Error {
  let code: Int
  let message: String
}

struct EmptyDecodable: Decodable {}

struct EmptyParams: Codable {}

struct InitializeRequest: Encodable {
  let method = "initialize"
  let id: Int
  let params: InitializeParams
}

struct InitializeParams: Encodable {
  let clientInfo: ClientInfo
}

struct ClientInfo: Encodable {
  let name: String
  let title: String
  let version: String
}

struct InitializedNotification: Encodable {
  let method = "initialized"
  let params = EmptyParams()
}

struct EmptyParamsRequest: Encodable {
  let method: String
  let id: Int
  let params = EmptyParams()
}

struct RateLimitUpdateNotification: Decodable {
  let method: String
  let params: RateLimitsEnvelope
}
