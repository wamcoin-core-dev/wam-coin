// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ===========================================================================
//  solo_template_test.cpp -- the two things a solo block is silently wrong in
// ===========================================================================
//
//      g++ -std=c++17 -I../src -o solo_template_test solo_template_test.cpp
//
//  Both of the bugs tested here were found by mining a throwaway regtest
//  chain, and neither could have been found by reading the code, because in
//  both cases the miner's arithmetic agreed with itself at every step. The
//  node was the only party that disagreed, and it disagreed in three words.
//
//    1. BIP34's height. Consensus does not compare the height as a NUMBER; it
//       builds `CScript() << nHeight` and compares BYTES. Heights 1 to 16 are
//       single opcodes, not data pushes. Written without that case, the miner
//       passed a proposal against mainnet at height 3351 and was refused on a
//       fresh chain at height 1 -- a bug that can only appear in the first
//       sixteen blocks of a chain, which is when nobody is watching.
//
//    2. The RandomX seed. getblocktemplate renders it the way a uint256
//       prints, big-endian; RandomX is keyed with the internal bytes. Keyed
//       with the wire order, the miner hashes against a key nobody else uses
//       and the node answers "high-hash" -- which reads as bad luck. On a real
//       chain it reads as a machine that never finds anything.
//
//  The template below is not invented. It was taken verbatim from a running
//  wamd with `getblocktemplate '{"rules":["segwit"]}'`.
// ===========================================================================

#include <cstdio>
#include <string>

#include "solo_template.h"

using namespace wam;

static int failures = 0;
static int checks   = 0;

static std::string Hex(const Bytes& b)
{
    static const char* d = "0123456789abcdef";
    std::string s;
    for (uint8_t c : b) { s += d[c >> 4]; s += d[c & 15]; }
    return s;
}

static void Eq(const std::string& got, const std::string& want, const char* what)
{
    checks++;
    if (got == want) {
        std::printf("  ok    %s\n", what);
        return;
    }
    failures++;
    std::printf("  FAIL  %s\n          wanted %s\n          got    %s\n",
                what, want.c_str(), got.c_str());
}

// ---------------------------------------------------------------------------

static void HeightVector(int64_t height, const char* wantHex)
{
    char what[80];
    std::snprintf(what, sizeof(what), "height %lld encodes as %s",
                  (long long)height, wantHex);
    Eq(Hex(HeightPush(height)), wantHex, what);
}

static void TestHeights()
{
    std::printf("\nBIP34 height, as CScript::push_int64 writes it\n");

    // OP_0. A coinbase at height 0 cannot exist -- genesis is not mined -- but
    // the encoding is defined and getting it wrong here would hide the shape
    // of the rule.
    HeightVector(0, "00");

    // OP_1 .. OP_16: one opcode, no length byte. This is the case that was
    // missing, and the only one a live chain stops exercising after its first
    // sixteen blocks.
    HeightVector(1,  "51");
    HeightVector(2,  "52");
    HeightVector(15, "5f");
    HeightVector(16, "60");

    // 17 is where data pushes begin: a length byte, then the number.
    HeightVector(17, "0111");

    // Real heights, little-endian. 88 was mined by this miner on regtest; 3351
    // is the mainnet height whose proposal the miner first got accepted.
    HeightVector(88,   "0158");
    HeightVector(3351, "02170d");

    // The sign byte. 128 has its top bit set, so a bare 0x80 would read as a
    // negative script number and the height would not match.
    HeightVector(127, "017f");
    HeightVector(128, "028000");
    HeightVector(255, "02ff00");

    // Three bytes, and a three-byte value whose top bit is clear needs no
    // fourth. 8388608 does need one.
    HeightVector(65535,   "03ffff00");
    HeightVector(8388607, "03ffff7f");
    HeightVector(8388608, "0400008000");
}

// ---------------------------------------------------------------------------

// Taken verbatim from a running wamd on regtest, at height 89, after the
// chain's first key rotation (randomx_seedheight 64) so the seed is a real
// block hash rather than the bootstrap constant.
static const char* kTemplate =
"{\"capabilities\":[\"proposal\"],\"version\":536870912,\"rules\":[\"csv\",\"!segwit\",\"taproot\"],"
"\"vbavailable\":{},\"vbrequired\":0,"
"\"previousblockhash\":\"11dca7308c1f95b844aa630cc6ffc8701015c5edd123a3a5ee5c53c08219c224\","
"\"transactions\":[],\"coinbaseaux\":{},\"coinbasevalue\":5000000000,"
"\"longpollid\":\"11dca7308c1f95b844aa630cc6ffc8701015c5edd123a3a5ee5c53c08219c22489\","
"\"target\":\"7fffff0000000000000000000000000000000000000000000000000000000000\","
"\"mintime\":1789854943,\"mutable\":[\"time\",\"transactions\",\"prevblock\"],"
"\"noncerange\":\"00000000ffffffff\",\"sigoplimit\":80000,\"sizelimit\":4000000,"
"\"weightlimit\":4000000,\"curtime\":1789855038,\"bits\":\"207fffff\",\"height\":89,"
"\"devfee\":{\"amount\":250000000,"
"\"script\":\"76a914a21b54367f4bd15b9b33e6e9e8b87c5b2fab5c1688ac\","
"\"address\":\"TQkMCz4r2oWuFjAu8mAeGYDMuz4BNkmofz\",\"percent\":5,"
"\"last_height\":400000,\"active\":true},"
"\"randomx_seedhash\":\"eca37065ee2bcb3fa020a90ccfb6c71b75d741fb5bac83023a1f14c68f5b1d4f\","
"\"randomx_seedheight\":64,"
"\"default_witness_commitment\":\"6a24aa21a9ede2f61c3f71d1defd3fa999dfa36953755c690689799962b48bebd836974e8cf9\"}";

static void TestTemplate()
{
    std::printf("\nA real getblocktemplate, turned into a job\n");

    json::Value t;
    std::string err;
    checks++;
    if (!json::ParseLine(kTemplate, t, err)) {
        failures++;
        std::printf("  FAIL  the captured template does not parse: %s\n", err.c_str());
        return;
    }
    std::printf("  ok    the captured template parses\n");

    const Bytes en1 = {0xde, 0xad, 0xbe, 0xef};
    SoloTemplate st = BuildSoloTemplate(t, "wamrt1q9uynnmupf5jl920vgztyef0v3esfjvdzfxfhyt",
                                        NetParamsFor("regtest"), "/wam-miner/", en1, 4);

    // THE SEED IS REVERSED. This single line is the whole test: the wire value
    // is big-endian and RandomX takes the internal bytes.
    Eq(Hex(st.job.seed),
       "4f1d5b8fc6141f3a0283ac5bfb41d7751bc7b6cf0ca920a03fcb2bee6570a3ec",
       "the RandomX key is the seed hash reversed");

    // Not the wire order, stated separately so a future change that quietly
    // drops the reversal fails with a message that names the mistake.
    checks++;
    if (Hex(st.job.seed) ==
        "eca37065ee2bcb3fa020a90ccfb6c71b75d741fb5bac83023a1f14c68f5b1d4f") {
        failures++;
        std::printf("  FAIL  the key is the wire order: every hash would be "
                    "computed against a seed nobody else uses\n");
    } else {
        std::printf("  ok    the key is not the wire order\n");
    }

    // The prevhash goes into the header little-endian, the reverse of how the
    // node states it -- the same conversion, on a different field.
    Eq(Hex(Bytes(st.job.prevHash, st.job.prevHash + 32)),
       "24c21982c0535ceea5a323d1edc5151070c8ffc60c63aa44b8951f8c30a7dc11",
       "the previous block hash is reversed into header order");

    Eq(std::to_string(st.job.height), "89", "the height is the template's");
    Eq(std::to_string(st.coinbaseValue), "5000000000", "the coinbase value is the template's");
    Eq(std::to_string(st.devFeeAmount), "250000000", "the treasury is 5% of the subsidy");

    // The height is in the coinbase where consensus looks for it: first byte
    // of the scriptSig, which for 89 is a one-byte data push.
    const Bytes en2 = {0x00, 0x00, 0x00, 0x01};
    const Bytes cb  = SerializeCoinbase(st.job, en2);
    const std::string cbHex = Hex(cb);
    checks++;
    if (cbHex.find("0159") != std::string::npos) {
        std::printf("  ok    the coinbase carries height 89 as a data push\n");
    } else {
        failures++;
        std::printf("  FAIL  the coinbase does not carry height 89\n");
    }
}

// ---------------------------------------------------------------------------

int main()
{
    std::printf("\nsolo_template_test\n");
    TestHeights();
    TestTemplate();
    std::printf("\n  %d checks, %d failure(s)\n\n", checks, failures);
    return failures ? 1 : 0;
}
