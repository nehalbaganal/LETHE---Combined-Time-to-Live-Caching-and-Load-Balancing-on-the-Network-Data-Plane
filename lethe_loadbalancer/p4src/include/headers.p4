/* Memcached Lethe Mk1 Load Balancer - Headers */

const bit<16> TYPE_IPV4 = 0x800;
const bit<8>  TYPE_TCP  = 6;
const bit<8>  TYPE_UDP  = 17;

const bit<16> MEMCACHED_UDP_PORT = 11212;


typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;


header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<6>    dscp;
    bit<2>    ecn;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header tcp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<32> seqNo;
    bit<32> ackNo;
    bit<4>  dataOffset;
    bit<4>  res;
    bit<1>  cwr;
    bit<1>  ece;
    bit<1>  urg;
    bit<1>  ack;
    bit<1>  psh;
    bit<1>  rst;
    bit<1>  syn;
    bit<1>  fin;
    bit<16> window;
    bit<16> checksum;
    bit<16> urgentPtr;
}

header udp_t {
    bit<16> srcPort;
    bit<16> dstPort;
    bit<16> length;
    bit<16> checksum;
}

/* Memcached UDP Frameheader */
header mcd_fh_t {
    bit<16> request_id;
    bit<16> seq_num;
    bit<16> num_dgram;
    bit<16> letheinfo;
}

/* Memcached Command Header */
header mcc_t {
    bit<24> command;  /* command - e.g. 'get', 'set', 'end', 'val' */
}

/* Memcached Default Header (shortened) - used by 'get', 'set', 'end'(modified) */
header mcd_t {
    bit<8>  space;    /* space */
    bit<352> key;     /* 16 bit key/two bytes */
    bit<16> crnl;     /* CR + NL */
}

/* Memcached VALUE Response Header - used by 'value' */
header mcr_t {
    bit<16> command;  /* 5 byte command: 'value' => 'ue' */
    bit<8> space;
    bit<352> key;
    bit<8> space1;
    bit<8> flags;     // 16+8+352+8+8=392
    // TODO: flags etc - must not contain "cas unique" for mset_t to work!
}

/* Memcached SET Header for converting VALUE Responses to SET Request */
header mset_t {
    bit<8> space;
    bit<352> key;
    bit<8> space1;
    bit<8> flags;
    bit<8> space2;
    bit<8> exptime;   // 8+352+8+8+8+8=392
    // Don't include noBytes but rather override VALUE Header and leave noBytes section untouched!
}

/* Memcached DELETE Response Header - used by 'delete' */
header mdel_t {
    bit<24>  command;  /* 6 byte command: 'delete' => 'ete' */
    bit<8>   space;
    bit<352> key;
    bit<16>  crnl;     /* CR + NL */
}

header mgat_t {
    bit<8>   space;
    bit<8>   exptime;
    bit<8>   space2;
    bit<352> key;
    bit<16>  crnl;
}

struct metadata {
    bit<14> ecmp_hash;
    bit<32> slb_hash;
}

struct headers {
    ethernet_t   ethernet;
    ipv4_t       ipv4;
    tcp_t        tcp;
    udp_t        udp;
    mcd_fh_t     mcdframe;
    mcc_t        mcommand;
    mcd_t        memcache;
    mcr_t        mcdvalue;
    mdel_t        mcdelete;
    mset_t       mcdset;
    mgat_t       mcdgat;
}
