/* -*- P4_16 -*- */
/* Memcached Lethe Mk1 Load Balancer - Main */
#include <core.p4>
#include <v1model.p4>

#include "include/headers.p4"
#include "include/parsers.p4"

const bit<16> NUM_SERVERS = 2;        // number of Memcached servers
const bit<32> REGISTER_SIZE = 65536;  // register size (maps hashed key to request count)

const bit<3>  HOTNESS_COLD = 0;
const bit<3>  HOTNESS_WARM1 = 1;
const bit<3>  HOTNESS_HOT = 2;
const bit<3>  HOTNESS_WARM2 = 3;

control MyVerifyChecksum(inout headers hdr,
                         inout metadata meta) {
    apply { }
}


control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    register<bit<16>>(REGISTER_SIZE) counterReg;  // 16-bit register


    /* part 1: hash based */
    action drop() {
        mark_to_drop(standard_metadata);
    }

    action forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
    }

    action set_server(macAddr_t dstMac, ip4Addr_t dstIp) {
        hdr.ethernet.dstAddr = dstMac;
        hdr.ipv4.dstAddr = dstIp;
    }

    action set_dummy_sender(macAddr_t srcMac, ip4Addr_t srcIp) {
        hdr.ethernet.srcAddr = srcMac;
        hdr.ipv4.srcAddr = srcIp;
    }


    action set_server_swap_src(macAddr_t dstMac, ip4Addr_t dstIp) {
        // set source address to original destination address
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ipv4.srcAddr = hdr.ipv4.dstAddr;

        // change destination address
        hdr.ethernet.dstAddr = dstMac;
        hdr.ipv4.dstAddr = dstIp;
    }

    action swap_port_udp() {
        bit<16> tmp = hdr.udp.srcPort;
        hdr.udp.srcPort = hdr.udp.dstPort;
        hdr.udp.dstPort = tmp;
    }

    /* part 3: increase counter for each key */
    action count_requests() {
        bit<16> count;
        counterReg.read(count, meta.slb_hash);
        count = count + 1;

        counterReg.write(meta.slb_hash, count);
    }

    /* stores the HOTness in the reserved section of the Memcached frame header
     * 0=cold 1=warm1 2=hot 3=warm2 */
    action store_hotness_in_packet(bit<3> hotness) {
        hdr.mcdframe.letheinfo = (bit<16>)hotness;
    }

    /* store the last 3 Bits of the Cache source address in Bits 6-8 of the Letheinfo Header */
    action store_cacheid_in_packet(ip4Addr_t cacheSrcAddr) {
        bit<16> cacheid = (bit<16>)cacheSrcAddr & 16w7;
        hdr.mcdframe.letheinfo = hdr.mcdframe.letheinfo | (cacheid << 5);  // Bit 6-8
    }

    table dmac {
        key = {
            hdr.ethernet.dstAddr: exact;
        }
        actions = {
            forward;
            NoAction;
        }
        size = 256;
        default_action = NoAction;
    }

    /* part n: distribute objects using meta.ecmp_hash (hashed key [WARM] OR request_id [HOT]) */
    table ecmp {
        key = {
            meta.ecmp_hash: exact;
        }
        actions = {
            NoAction;
            set_server;
        }
        size = 256;
        default_action = NoAction;
    }

    /* part n: match-action table with HOTness (HOT/WARM1/WARM2/COLD) per hashed key */
    action set_server_hot() {
        hash(meta.ecmp_hash,
            HashAlgorithm.crc16,
            (bit<1>)0,
            {hdr.mcdframe.request_id},
            NUM_SERVERS); // <- modulo, num servers
        store_hotness_in_packet(HOTNESS_HOT);
    }
    action set_server_warm1() {
        meta.ecmp_hash = 0; // <- modulo, num servers
        store_hotness_in_packet(HOTNESS_WARM1);
    }
    action set_server_warm2() {
        meta.ecmp_hash = 1;
        store_hotness_in_packet(HOTNESS_WARM2);
    }
    action set_server_cold() {
        meta.ecmp_hash = 16383;  // ecmp->NoAction (fetch from Database)
        store_hotness_in_packet(HOTNESS_COLD);
    }
    table loadbal {
        key = {
            meta.slb_hash: exact;
        }
        actions = {
            set_server_hot;
            set_server_warm1;
            set_server_cold;
            set_server_warm2;
        }
        size = 1200;
        default_action = set_server_cold;
    }

    /* match object HOTness(from Memcached frame header) to an action (e.g. set multicast group).
     * Used by: Store Database response to Caches */
    action phot_hot() {
        standard_metadata.mcast_grp = 4 + (bit<16>)(16 * ((hdr.ipv4.dstAddr >> 2) & 0b00000001));
        log_msg("phot: HOT={} MCG={}", {hdr.mcdframe.letheinfo, standard_metadata.mcast_grp});
    }
    action phot_warm1() {
        bit<16> cache_id;
        cache_id = 0; // <- modulo, num servers
        standard_metadata.mcast_grp = 2+cache_id + (bit<16>)(16 * ((hdr.ipv4.dstAddr >> 2) & 0b00000001));  // cache 0 is mcast grp 3, 1 is group 4
        log_msg("phot: WARM={} CACHE_ID={} MCG={}", {hdr.mcdframe.letheinfo, cache_id, standard_metadata.mcast_grp});
    }
    action phot_warm2() {
        bit<16> cache_id;
        cache_id = 1;
        standard_metadata.mcast_grp = 2+cache_id + (bit<16>)(16 * ((hdr.ipv4.dstAddr >> 2) & 0b00000001));
    }
    action phot_cold() {
        log_msg("phot: COLD {}", {hdr.mcdframe.letheinfo});
    }
    table phot {
        key = {
            hdr.mcdframe.letheinfo: ternary;
        }
        actions = {
            phot_hot;
            phot_warm1;
            phot_cold;
            phot_warm2;
        }
        size = 4;
        default_action = phot_cold;
    }

    apply {
        /* Part A: Client -> Server*/
        if (hdr.ipv4.isValid() && hdr.udp.dstPort == 11212) {

            hash(meta.slb_hash,
                    HashAlgorithm.crc32,
                    (bit<1>)0,
                    {hdr.memcache.key},
                    REGISTER_SIZE);

            /* GET request (command starts with 'g'(0x67)) */
            if (((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x47) {
                count_requests();

                loadbal.apply();
                ecmp.apply();

                /* Change GET to GAT with expiration time if not fetched from DB (=is COLD) */
                if (hdr.mcdframe.letheinfo != (bit<16>)HOTNESS_COLD) {
                    hdr.mcdgat.setValid();
                    hdr.mcommand.command = 6775156; // gat
                    hdr.mcdgat.space = 0x20;
                    hdr.mcdgat.exptime = 0x35;    // hardcoded 5s exptime extend (TODO)
                    hdr.mcdgat.space2 = 0x20;
                    hdr.mcdgat.key = hdr.memcache.key;
                    hdr.mcdgat.crnl = 0x0D0A;
                    hdr.ipv4.totalLen = hdr.ipv4.totalLen + 2;
                    hdr.udp.length = hdr.udp.length + 2;
                    hdr.memcache.setInvalid();
                }

                log_msg("GET request");
            }
            /* SET request (command starts with 's'(0x73)) */
            else if (((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x53) {
                standard_metadata.mcast_grp = 1;
                log_msg("SET request");
            }

        }

        /* Part B: Server -> Client */
        else if (hdr.udp.isValid() && hdr.udp.srcPort == 11212) {
            /* Source is database server (00:00:0a:00:00:04) */
            if (hdr.ipv4.srcAddr == 167772164) {
                /* GET response HIT (command starts with 'v'(0x76)) */
                if (hdr.mcdvalue.isValid() && ((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x56) {
                    // TODO: Part C (clone packet to client and one/multiple caches)
                    phot.apply();
                    log_msg("DB: GET response HIT");
                    hdr.mcdframe.letheinfo = hdr.mcdframe.letheinfo + 16;  // debug info: 16+n=response if from db,n=Hotness
                }
                /* GET response MISS (command starts with 'e'(0x65)) */
                else if (hdr.memcache.isValid() && ((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x45) {
                    // TODO: Send back MISS as data is neither in cache, nor database
                    log_msg("DB: GET response MISS");
                }
                else {
                    log_msg("DB: Something else");
                }
            }
            /* Source is not database -> is cache */
            else {
                /* GET response HIT (command starts with 'v'(0x76)) */
                if (hdr.mcdvalue.isValid() && ((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x56) {
                    store_cacheid_in_packet(hdr.ipv4.srcAddr);
                    set_dummy_sender(167772164, 167772164); // 00:00:0a:00:00:04 10.0.0.4
                    log_msg("C: GET response HIT: VALUE");
                }
                /* GET response MISS (command starts with 'e'(0x65)) */
                else if (hdr.memcache.isValid() &&  ((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x45) {
                    store_cacheid_in_packet(hdr.ipv4.srcAddr);
                    // Modify packet to get response to database (replace "end <key>" with "get <key>")
                    //   -> requires modified Memcached with "end <key>"" response!
                    hdr.mcommand.command = 6776180;  // "get"

                    // Forward request to database server (sender=client!)
                    set_server_swap_src(167772164, 167772164); // 00:00:0a:00:00:04 10.0.0.4
                    swap_port_udp();
                    log_msg("C: GET response MISS: END");
                }
                /* DELETE response NOT FOUND or DELETE (command starts with 'n'(0x6E)/'d'(0x64)) */
                else if (hdr.mcommand.isValid() && (((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x4E ||
                                                    ((bit<8>)(hdr.mcommand.command >> 16)) & 0b11011111 == 0x44)) {
                    drop();
                    hdr.udp.dstPort = 12345; // ensure packet doesn't arrive as drop() isn't reliable for some reason (TODO)
                    log_msg("C: Drop NOT_FOUND / DELETE");
                }
                else {
                    log_msg("C: somethign else {}", {((bit<8>)(hdr.mcommand.command >> 16))});
                }
            }
        }

        dmac.apply();
    }
}


control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {

    /* this must be named different from set_server in the Ingress to provent a problem with the ecmp table's action set_server! */
    action egress_set_server(macAddr_t dstMac, ip4Addr_t dstIp) {
        hdr.ethernet.dstAddr = dstMac;
        hdr.ipv4.dstAddr = dstIp;
    }

    action egress_swap_port_udp() {
        bit<16> tmp = hdr.udp.srcPort;
        hdr.udp.srcPort = hdr.udp.dstPort;
        hdr.udp.dstPort = tmp;
    }

    apply {
        /* Part X: Invalidate object in all Caches on SET request */
        if (standard_metadata.mcast_grp == 1) {
            /* SET request for DB*/
            if (standard_metadata.egress_rid == 1) {
                log_msg("Egress: Invalidate: SET to DB");
                egress_set_server(167772164, 167772164);   /* DB @ 10.0.0.4 */
            }
            /* DELETE request for Cache */
            else {
                log_msg("Egress: Invalidate: DELETE to Cache");
                /* Cache, 10.0.0.n where n=egress_port */
                bit<32> cache_server = 167772160 + (bit<32>)standard_metadata.egress_port;
                egress_set_server((bit<48>)cache_server, cache_server);

                /* Modify header: SET <key> to DELETE <key> */
                hdr.mcdelete.setValid();

                hdr.mcdelete.key = hdr.memcache.key;
                hdr.mcdelete.space = hdr.memcache.space;

                hdr.mcommand.command = 6579564 ; /* 'del' */
                hdr.mcdelete.command = 6648933; /* 'ete'*/
                hdr.mcdelete.crnl = 3338; /* CR + NL */

                hdr.ipv4.totalLen = 89;
                hdr.udp.length = 69;

                hdr.memcache.setInvalid();

                truncate(103);
            }
        }
        /* Part Y: Store data from Database response to one/all Caches */
        else if (standard_metadata.mcast_grp > 1) {
            /* VALUE response for Client */
            if (standard_metadata.egress_rid == 1) {
                log_msg("Egress: VALUE to Client");
            }
            /* SET request for Cache */
            else {
                log_msg("Egress: Modify VALUE: SET to Cache {}", {standard_metadata.egress_port});
                /* Cache, 10.0.0.n where n=egress_port */
                bit<32> cache_server = 167772160 + (bit<32>)standard_metadata.egress_port;
                egress_set_server((bit<48>)cache_server, cache_server);

                /* Modify header: VALUE <key> <flags> <bytes> to set <key> <flags> <exptime> <bytes> */
                hdr.mcdset.setValid();

                hdr.mcommand.command = 7562612 ; /* 'set' */

                hdr.mcdset.key = hdr.mcdvalue.key;
                hdr.mcdset.flags = hdr.mcdvalue.flags;
                hdr.mcdset.space = 0x20;
                hdr.mcdset.space1 = 0x20;
                hdr.mcdset.space2 = 0x20;
                hdr.mcdset.exptime = 0x35;  // Hardcoded 5 second expiration time (for testing)

                egress_swap_port_udp();

                bit<16> oldLen = hdr.ipv4.totalLen;  // TODO: cut off 50 bytes ("END <key 44>\r\n")
                //hdr.ipv4.totalLen = oldLen-50;
                //hdr.udp.length = oldLen-70;

                hdr.mcdvalue.setInvalid();

                //truncate((bit<32>)oldLen-36);
            }
        }
    }
}


control MyComputeChecksum(inout headers hdr,
                          inout metadata meta) {
    apply {
        /* Update IPv5 Checksum */
        update_checksum(
            hdr.ipv4.isValid(),
                { hdr.ipv4.version,
                hdr.ipv4.ihl,
                hdr.ipv4.dscp,
                hdr.ipv4.ecn,
                hdr.ipv4.totalLen,
                hdr.ipv4.identification,
                hdr.ipv4.flags,
                hdr.ipv4.fragOffset,
                hdr.ipv4.ttl,
                hdr.ipv4.protocol,
                hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);

        /* Update UDP Checksum for memcache header */
        update_checksum_with_payload(
            hdr.udp.isValid() && hdr.memcache.isValid(),
                { hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr,
                (bit<16>)TYPE_UDP,
                hdr.udp.length,
                hdr.udp.length,
                hdr.udp.srcPort,
                hdr.udp.dstPort,
                hdr.mcdframe.request_id,
                hdr.mcdframe.seq_num,
                hdr.mcdframe.num_dgram,
                hdr.mcdframe.letheinfo,
                hdr.mcommand.command,
                hdr.memcache.space,
                hdr.memcache.key,
                hdr.memcache.crnl },
            hdr.udp.checksum,
            HashAlgorithm.csum16);

        /* Update UDP Checksum for mcdset header */
        update_checksum_with_payload(
            hdr.udp.isValid() && hdr.mcdset.isValid(),
                { hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr,
                (bit<16>)TYPE_UDP,
                hdr.udp.length,
                hdr.udp.length,
                hdr.udp.srcPort,
                hdr.udp.dstPort,
                hdr.mcdframe.request_id,
                hdr.mcdframe.seq_num,
                hdr.mcdframe.num_dgram,
                hdr.mcdframe.letheinfo,
                hdr.mcommand.command,
                hdr.mcdset.space,
                hdr.mcdset.key,
                hdr.mcdset.space1,
                hdr.mcdset.flags,
                hdr.mcdset.space2,
                hdr.mcdset.exptime },
            hdr.udp.checksum,
            HashAlgorithm.csum16);

        /* Update UDP Checksum for mcdvalue header */
        update_checksum_with_payload(
            hdr.udp.isValid() && hdr.mcdvalue.isValid(),
                { hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr,
                (bit<16>)TYPE_UDP,
                hdr.udp.length,
                hdr.udp.length,
                hdr.udp.srcPort,
                hdr.udp.dstPort,
                hdr.mcdframe.request_id,
                hdr.mcdframe.seq_num,
                hdr.mcdframe.num_dgram,
                hdr.mcdframe.letheinfo,
                hdr.mcommand.command,
                hdr.mcdvalue.command,
                hdr.mcdvalue.space,
                hdr.mcdvalue.key,
                hdr.mcdvalue.space1,
                hdr.mcdvalue.flags },
            hdr.udp.checksum,
            HashAlgorithm.csum16);

        /* Update UDP Checksum for mcdelete header */
        /* Don't use update_checksum_with_payload! */
        update_checksum(
            hdr.udp.isValid() && hdr.mcdelete.isValid(),
                { hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr,
                (bit<16>)TYPE_UDP,
                hdr.udp.length,
                hdr.udp.length,
                hdr.udp.srcPort,
                hdr.udp.dstPort,
                hdr.mcdframe.request_id,
                hdr.mcdframe.seq_num,
                hdr.mcdframe.num_dgram,
                hdr.mcdframe.letheinfo,
                hdr.mcommand.command,
                hdr.mcdelete.command,
                hdr.mcdelete.space,
                hdr.mcdelete.key,
                hdr.mcdelete.crnl },
            hdr.udp.checksum,
            HashAlgorithm.csum16);

        /* Update UDP Checksum for mcdgat header */
        update_checksum_with_payload(
            hdr.udp.isValid() && hdr.mcdgat.isValid(),
                { hdr.ipv4.srcAddr,
                hdr.ipv4.dstAddr,
                (bit<16>)TYPE_UDP,
                hdr.udp.length,
                hdr.udp.length,
                hdr.udp.srcPort,
                hdr.udp.dstPort,
                hdr.mcdframe.request_id,
                hdr.mcdframe.seq_num,
                hdr.mcdframe.num_dgram,
                hdr.mcdframe.letheinfo,
                hdr.mcommand.command,
                hdr.mcdgat.space,
                hdr.mcdgat.exptime,
                hdr.mcdgat.space2,
                hdr.mcdgat.key,
                hdr.mcdgat.crnl },
            hdr.udp.checksum,
            HashAlgorithm.csum16);
    }
}


V1Switch(
    MyParser(),
    MyVerifyChecksum(),
    MyIngress(),
    MyEgress(),
    MyComputeChecksum(),
    MyDeparser()
) main;
