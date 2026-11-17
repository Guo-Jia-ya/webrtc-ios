//
//  MainServerAPI.swift
//  主服务器的 HTTP 接口（登录 / 注册）
//
//  协议对照（servers/main/router/user.js）：
//    POST /api/login   {id, password}
//      → {status:0, message, token:"Bearer xxx", url, name, id}
//      失败时 status != 0，message 是中文提示
//    POST /api/reguser {id, password, name}
//      → {status:0, message:"注册成功！", url}
//
//  注意：注册接口的 id 只允许字母数字，密码 6~12 位（服务端 joi 校验），
//  客户端先做一次同样的校验，避免白跑一趟网络请求。
//

import Foundation

enum MainServerAPI {

    enum APIError: LocalizedError {
        case badURL
        case network(String)
        case server(String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .badURL: return "服务器地址无效"
            case .network(let m): return "网络错误：\(m)"
            case .server(let m): return m
            case .badResponse: return "服务器返回格式异常"
            }
        }
    }

    static func login(endpoint: Endpoint, id: String, password: String) async throws -> LoginResult {
        let json = try await post(endpoint: endpoint, path: "/api/login",
                                  body: ["id": id, "password": password])
        guard let status = json["status"] as? Int, status == 0 else {
            throw APIError.server((json["message"] as? String) ?? "登录失败")
        }
        guard let token = json["token"] as? String else { throw APIError.badResponse }
        return LoginResult(token: token,
                           name: (json["name"] as? String) ?? id,
                           userId: (json["id"] as? String) ?? id)
    }

    @discardableResult
    static func register(endpoint: Endpoint, id: String, password: String, name: String) async throws -> String {
        let json = try await post(endpoint: endpoint, path: "/api/reguser",
                                  body: ["id": id, "password": password, "name": name])
        guard let status = json["status"] as? Int, status == 0 else {
            throw APIError.server((json["message"] as? String) ?? "注册失败")
        }
        return (json["message"] as? String) ?? "注册成功"
    }

    private static func post(endpoint: Endpoint, path: String, body: [String: String]) async throws -> [String: Any] {
        guard let url = URL(string: endpoint.display + path) else { throw APIError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            // 主服务器是 http 明文，用默认 session 即可；这里统一用 insecure，
            // 万一用户给主服务器配了 https 自签证书也能连。
            let (data, resp) = try await SharedSession.insecure.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                throw APIError.server("服务器返回 HTTP \(http.statusCode)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw APIError.badResponse
            }
            return obj
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }
}
