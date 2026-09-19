// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  solo.h -- mine for yourself, against your own node
// ===========================================================================
//
//      wam-miner --solo --rpc 127.0.0.1:9554 -u <your address> -t 4
//
//  WHY THIS EXISTS
//
//  Until 19 September 2026 mining alone on this chain meant running the pool
//  software for one person: Redis, a native RandomX addon, node-gyp, and a
//  guide written for somebody serving other people. On Linux that is an
//  evening's work. On Windows it is not practical at all.
//
//  Meanwhile the project's own mining guide says -- correctly -- that a solo
//  miner helps this chain more than joining any pool does, because every solo
//  miner is a distinct finder and a pool is one finder however many people
//  stand behind it. Advice nobody can follow is not advice.
//
//  WHAT IT DOES AND DOES NOT DO
//
//  It replaces the pool, not the miner. The same workers hash the same jobs
//  through the same BuildHeader; only the source of work and the destination
//  of a solution change. There is no share difficulty here and nothing is
//  submitted until a hash meets the BLOCK target -- alone, a share is worth
//  nothing to anybody.
//
//  It polls rather than long-polls. getblocktemplate is cheap against a local
//  node, a stale template costs at most one block interval, and long-polling
//  would mean a second connection whose failure mode is silence.
// ===========================================================================

#pragma once

#include <atomic>
#include <cstdint>
#include <deque>
#include <fstream>
#include <mutex>
#include <random>
#include <string>
#include <utility>

#include "rpc.h"
#include "solo_template.h"
#include "util.h"

namespace wam {

class SoloSession {
public:
    SoloSession(RpcClient& rpc, std::string address, NetAddressParams net,
                std::string signature)
        : m_rpc(rpc), m_address(std::move(address)), m_net(std::move(net)),
          m_signature(std::move(signature))
    {
        // extranonce1 is this session's own, the way a pool would assign one:
        // it separates two miners paying the same address from each other.
        std::random_device rd;
        for (int i = 0; i < 4; i++) m_extranonce1.push_back(uint8_t(rd()));
    }

    /** Called when a new template should be fetched. Returns false on error. */
    bool Refresh(std::string& error)
    {
        try {
            const json::Value t =
                m_rpc.Call("getblocktemplate", "[{\"rules\":[\"segwit\"]}]");
            SoloTemplate st = BuildSoloTemplate(t, m_address, m_net, m_signature,
                                                m_extranonce1, 4);
            const bool isNew = st.prevHashHex != m_current.prevHashHex ||
                               st.job.height  != m_current.job.height;

            // Every template gets its own id, height alone is not enough: the
            // node hands out a fresh one whenever the mempool moves, and two
            // templates at the same height carry different transactions. A
            // worker solving the older one must be given the transactions
            // THAT job promised, which is what the ids below are for.
            st.job.jobId = std::to_string(st.job.height) + "." +
                           std::to_string(++m_serial);
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                m_issued.emplace_back(st.job.jobId, st.txs);
                while (m_issued.size() > 8) m_issued.pop_front();
            }

            m_current = std::move(st);
            m_haveTemplate = true;
            m_isNew = isNew;
            return true;
        } catch (const std::exception& e) {
            error = e.what();
            return false;
        }
    }

    bool HaveTemplate() const { return m_haveTemplate; }
    bool WasNew() const { return m_isNew; }
    const SoloTemplate& Current() const { return m_current; }

    /**
     * Hand a solved block to the node.
     *
     * `job` is the job the worker actually hashed, which may be older than
     * the template held here if a new block arrived mid-hash. It carries
     * everything the block needs, so it is used rather than m_current: a
     * block built from a different template than the one that was hashed
     * would have a merkle root that does not match its own header.
     *
     * The transactions are looked up by the job's own id for the same reason.
     * Reaching for the CURRENT template's transactions instead builds a block
     * whose body does not match the merkle root in its header -- rare, since
     * it needs the mempool to move between handing out the job and solving
     * it, and silent when it is not rare enough.
     *
     * `blockHexOut` receives the exact bytes sent, whatever the answer. A
     * rejected block is a solved block thrown away; keeping what was sent is
     * the difference between diagnosing it and guessing.
     */
    std::string Submit(const StratumJob& job, const Bytes& extranonce2,
                       uint32_t nonce, std::string* blockHexOut = nullptr)
    {
        std::vector<TemplateTx> txs;
        bool known = false;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            for (const auto& e : m_issued) {
                if (e.first == job.jobId) { txs = e.second; known = true; break; }
            }
        }
        if (!known) {
            throw std::runtime_error(
                "job " + job.jobId + " is no longer held, so the transactions "
                "it was built from are unknown. The block is not sent rather "
                "than sent wrong.");
        }

        uint8_t header[80];
        BuildHeader(job, extranonce2, header);
        WriteLE32(header + 76, nonce);

        const Bytes coinbase = SerializeCoinbaseWithWitness(job, extranonce2);
        const Bytes block    = SerializeBlock(header, coinbase, txs);
        const std::string hex = ToHex(block);
        if (blockHexOut) *blockHexOut = hex;

        const json::Value r = m_rpc.Call("submitblock", "[\"" + hex + "\"]");

        // submitblock answers null when the block is accepted and a reason
        // when it is not. Both arrive down the same channel, which is why the
        // null is checked rather than assumed.
        return r.IsNull() ? std::string() : r.AsString("rejected");
    }

private:
    RpcClient&        m_rpc;
    std::string       m_address;
    NetAddressParams  m_net;
    std::string       m_signature;
    Bytes             m_extranonce1;

    SoloTemplate m_current;
    bool         m_haveTemplate = false;
    bool         m_isNew        = false;

    // Workers submit from their own threads, so the issued list is shared.
    mutable std::mutex m_mutex;
    std::deque<std::pair<std::string, std::vector<TemplateTx>>> m_issued;
    uint64_t m_serial = 0;
};

}   // namespace wam
