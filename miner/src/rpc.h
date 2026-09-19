// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  rpc.h -- ask the node a question, over HTTP, the way bitcoin-cli does
// ===========================================================================
//
//  Mining alone means talking to a node instead of to a pool: getblocktemplate
//  to learn what to build, submitblock to hand back what was built. Both are
//  JSON-RPC over HTTP, and the node answers on 9554.
//
//  WHY THIS IS SMALL AND DELIBERATELY DULL
//
//  It speaks exactly enough HTTP to post a body and read one back: a request
//  line, four headers, Basic auth, and a reply whose length the node always
//  declares. No chunked encoding, no keep-alive, no redirects, no TLS. The
//  node is on the same machine or the same room; a general HTTP client here
//  would be more code to be wrong in.
//
//  HOW IT AUTHENTICATES
//
//  Two ways, and the second is the one most people will use without knowing
//  it exists:
//
//    1. rpcuser / rpcpassword from wam.conf, passed on the command line.
//    2. The cookie. A node with no rpcuser writes <datadir>/.cookie at
//       startup, containing `__cookie__:<random>`, and that is exactly a
//       Basic auth pair. bitcoin-cli reads it and so does this. It means a
//       miner on the same machine needs no credentials at all -- and a node
//       that is restarted writes a new one, so it is read per call rather
//       than once.
//
//  WHAT IT REFUSES TO GUESS
//
//  An HTTP 401 is reported as an authentication failure and not as a network
//  problem, because the two are fixed differently and a miner told "could not
//  reach the node" will spend the evening on the firewall.
// ===========================================================================

#pragma once

#include <cstdint>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>

#include "json.h"
#include "platform.h"
#include "util.h"

namespace wam {

/** RFC 4648 base64, for the one Authorization header. */
inline std::string Base64(const std::string& in)
{
    static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                           "abcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    while (i + 2 < in.size()) {
        const uint32_t v = (uint8_t(in[i]) << 16) | (uint8_t(in[i + 1]) << 8) |
                            uint8_t(in[i + 2]);
        out += t[(v >> 18) & 63]; out += t[(v >> 12) & 63];
        out += t[(v >> 6) & 63];  out += t[v & 63];
        i += 3;
    }
    if (i + 1 == in.size()) {
        const uint32_t v = uint32_t(uint8_t(in[i])) << 16;
        out += t[(v >> 18) & 63]; out += t[(v >> 12) & 63];
        out += "==";
    } else if (i + 2 == in.size()) {
        const uint32_t v = (uint32_t(uint8_t(in[i])) << 16) |
                           (uint32_t(uint8_t(in[i + 1])) << 8);
        out += t[(v >> 18) & 63]; out += t[(v >> 12) & 63];
        out += t[(v >> 6) & 63];  out += '=';
    }
    return out;
}

class RpcClient {
public:
    RpcClient(std::string host, int port, std::string user,
              std::string password, std::string cookiePath)
        : m_host(std::move(host)), m_port(port), m_user(std::move(user)),
          m_pass(std::move(password)), m_cookie(std::move(cookiePath)) {}

    /**
     * One call. Returns the `result` member, or throws with what the node
     * said -- its message, not ours, because the node knows why.
     */
    json::Value Call(const std::string& method, const std::string& paramsJson)
    {
        const std::string body =
            "{\"jsonrpc\":\"1.0\",\"id\":\"wam-miner\",\"method\":\"" + method +
            "\",\"params\":" + (paramsJson.empty() ? "[]" : paramsJson) + "}";

        int status = 0;
        const std::string reply = Post(body, status);

        if (status == 401) {
            throw std::runtime_error(
                "the node refused the credentials (HTTP 401). Either pass "
                "--rpcuser and --rpcpassword matching wam.conf, or let the "
                "miner read <datadir>/.cookie -- which only works if the node "
                "has no rpcuser set.");
        }

        json::Value root;
        std::string jsonError;
        if (!json::ParseLine(reply, root, jsonError)) {
            throw std::runtime_error("the node's reply was not JSON (" +
                                     jsonError + "): " + reply.substr(0, 160));
        }

        const json::Value& err = root["error"];
        if (!err.IsNull()) {
            const std::string msg = err["message"].AsString();
            throw std::runtime_error(method + ": " +
                (msg.empty() ? "the node returned an error" : msg));
        }

        // A null result is not an error and must not be treated as one.
        //
        // JSON-RPC answers every successful call with both members present,
        // and `error` above is the one that says whether it went wrong. Null
        // is the SUCCESS value for the two calls this miner cares about most:
        // submitblock answers null when a block is accepted, and
        // getblocktemplate in proposal mode answers null when the block it
        // was shown is valid.
        //
        // Throwing on it cost an evening: the first correctly built block
        // this miner ever proposed was accepted by the node and reported here
        // as "the reply carried no result".
        return root["result"];
    }

private:
    /** Basic auth pair, read fresh: a restarted node writes a new cookie. */
    std::string Credentials() const
    {
        if (!m_user.empty()) return m_user + ":" + m_pass;
        if (m_cookie.empty()) {
            throw std::runtime_error(
                "no RPC credentials. Pass --rpcuser and --rpcpassword, or "
                "--rpccookie pointing at the node's .cookie file.");
        }
        std::ifstream f(m_cookie, std::ios::binary);
        if (!f) {
            throw std::runtime_error("cannot read the cookie at " + m_cookie +
                                     ". Is the node running, and is this the "
                                     "right datadir?");
        }
        std::string line;
        std::getline(f, line);
        while (!line.empty() && (line.back() == '\r' || line.back() == '\n')) {
            line.pop_back();
        }
        if (line.find(':') == std::string::npos) {
            throw std::runtime_error("the cookie at " + m_cookie +
                                     " is not in user:password form");
        }
        return line;
    }

    std::string Post(const std::string& body, int& status)
    {
        addrinfo hints{};
        hints.ai_family   = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;

        addrinfo* res = nullptr;
        const std::string portStr = std::to_string(m_port);
        if (getaddrinfo(m_host.c_str(), portStr.c_str(), &hints, &res) != 0 || !res) {
            throw std::runtime_error("cannot resolve " + m_host);
        }

        sock_t s = kInvalidSock;
        for (addrinfo* a = res; a; a = a->ai_next) {
            s = ::socket(a->ai_family, a->ai_socktype, a->ai_protocol);
            if (s == kInvalidSock) continue;
            SetSockTimeout(s, SO_RCVTIMEO, 30);
            SetSockTimeout(s, SO_SNDTIMEO, 30);
            if (ConnectTo(s, a->ai_addr, a->ai_addrlen) == 0) break;
            CloseSock(s);
            s = kInvalidSock;
        }
        freeaddrinfo(res);

        if (s == kInvalidSock) {
            throw std::runtime_error(
                "cannot reach the node at " + m_host + ":" + portStr +
                ". Is wamd running, and does wam.conf have server=1?");
        }

        std::ostringstream req;
        req << "POST / HTTP/1.1\r\n"
            << "Host: " << m_host << ":" << m_port << "\r\n"
            << "Authorization: Basic " << Base64(Credentials()) << "\r\n"
            << "Content-Type: application/json\r\n"
            << "Content-Length: " << body.size() << "\r\n"
            << "Connection: close\r\n\r\n"
            << body;
        const std::string out = req.str();

        size_t sent = 0;
        while (sent < out.size()) {
            const long n = SendSome(s, out.data() + sent, out.size() - sent);
            if (n <= 0) { CloseSock(s); throw std::runtime_error("the node closed the connection while being asked"); }
            sent += size_t(n);
        }

        std::string reply;
        char buf[8192];
        for (;;) {
            const long n = RecvSome(s, buf, sizeof(buf));
            if (n > 0) { reply.append(buf, size_t(n)); continue; }
            break;                      // Connection: close, so EOF ends it
        }
        CloseSock(s);

        // ---- split the reply -------------------------------------------------
        const size_t sep = reply.find("\r\n\r\n");
        if (sep == std::string::npos) {
            throw std::runtime_error("the node's reply had no HTTP headers");
        }
        const std::string head = reply.substr(0, sep);

        status = 0;
        const size_t sp = head.find(' ');
        if (sp != std::string::npos) status = std::atoi(head.c_str() + sp + 1);

        return reply.substr(sep + 4);
    }

    std::string m_host;
    int         m_port;
    std::string m_user;
    std::string m_pass;
    std::string m_cookie;
};

}   // namespace wam
