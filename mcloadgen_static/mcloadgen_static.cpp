/* Very fast Memcached load generator "mcloadgen_static"
 * Algorithm:
 * - Generate random objects (key, value, inter-request time)
 * - Store all objects in the cache
 * - Schedule and send the requests for the object "schedule_task"
 * - Receive responses in a separate thread and calculate the response time and hits/misses "receive_memc_response_task"
 * 
 * Characteristics:
 * - Static objects (generated when program is started)
 * - Static inter-request time
 * - Expiration time will not be extended on get (not "gat")
 * - GET requests via UDP
 * - Fills cache with objects and random data (over UDP)
 *
 * David Munstein @ NCS, October 2022
 */

#include <iostream>
#include <fstream>
#include <random>
#include <chrono>
#include <thread>
#include <map>
#include <mutex>
#include <string>
#include <boost/array.hpp>
#include <boost/asio.hpp>
#include <boost/thread.hpp>
//#include <libmemcached/memcached.h>
#include <math.h>
#include "testvariables.h"

// using namespace std;
using namespace boost::asio;

double alpha;
int num_objects;
int total_request_limit;
int run_id; //This is to determine which run of the experiment it is? Used to diferentaite the output files

const int key_length = KEY_LENGTH;
const int value_size_min = VALUE_SIZE_MIN;
const int value_size_max = VALUE_SIZE_MAX;
const int percent_hot = 1; // The 5% of object with lowest inter-requets time are considered HOT
const int test_duration_seconds = TEST_DURATION_SECONDS;
int distribution_type = 0;

// Values for randomly generating inter-request times: irt = 1 / exp_random()
const double exp_dist_mean = IRT_EXP_DIST_MEAN;
const double exp_dist_lambda = 1 / exp_dist_mean;

// Available characters used for generating the key and value
const char key_chars[] = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+=";

// Memcached server configuration (UDP and TCP port, e.g. 11212 and 11211)
std::string memc_host;
const int memc_tport = 11211;
const int memc_uport = 11212;
char memc_config[32];

/* RUNTIME VARIABLES*/

// Memcached request id, will be incremented for each request (overflow to 0 after 65536 requests)
uint16_t request_id = 0;

// Maps the time of request (timepoint) to a request id (uint16_t)
std::map<uint16_t, std::chrono::time_point<std::chrono::high_resolution_clock>> request_times;
std::mutex rtm;

/* struct for storing response information, used for evaluation */
struct response_record
{
    uint16_t request_id;
    int64_t timestamp_us;
    uint32_t response_time_us;
    uint16_t letheinfo_hdr;
    bool is_hit;
};

std::vector<response_record> response_list;

uint32_t num_requests = 0;      // counter for requests made

/* struct for Memcached key-value objects */
struct kv_object
{
    std::string key; // Memcached key
    int irt_ms;      // inter-request time in milliseconds
    int value_len;   // length of the value
    std::chrono::time_point<std::chrono::high_resolution_clock> next_call;
};

std::vector<int> zipf_popularities;

/* generate a random string with length {len} using characters from {key_chars} */
std::string gen_random_string(const int len)
{
    std::string s;
    s.reserve(len);
    for (int i = 0; i < len; i++)
    {
        s += key_chars[rand() % (sizeof(key_chars) - 1)];
    }
    return s;
}

/* generate {count} random objects and store them to {objects} */
void generate_random_kvobjects(kv_object *objects, int count)
{
    std::random_device rd;

    std::exponential_distribution<> rng(exp_dist_lambda);
    std::mt19937 rng_gen(rd());

    for (int i = 0; i < count; i++)
    {
        double rps = rng(rng_gen);
        double irt = 1 / rps * 1000;
        objects[i].key = gen_random_string(key_length);
        objects[i].irt_ms = int(irt);
        objects[i].value_len = value_size_min + rand() % (value_size_max - value_size_min);
    }
}

/* sort kv objects by irt ascending using bubblesort */
void sort_objects_irt_asc(kv_object *objects, int count)
{
    kv_object tmp;
    for (int n = count; n > 1; n--)
    {
        for (int i = 0; i < n - 1; i++)
        {
            if (objects[i].irt_ms > objects[i + 1].irt_ms)
            {
                tmp = objects[i];
                objects[i] = objects[i + 1];
                objects[i + 1] = tmp;
            }
        }
    }
}

/* sends a set request to Memcached via UDP - doesn't care about response */
void do_udp_set_request(std::string skey, std::string svalue, int flags, int exptime, ip::udp::socket *socket, ip::udp::endpoint *receiver_endpoint)
{
    const char *key = skey.c_str();
    const char *value = svalue.c_str();

    char flagsc[4];
    char exptimec[4];
    char value_lenc[8];

    sprintf(flagsc, "%d", flags);
    sprintf(exptimec, "%d", exptime);
    sprintf(value_lenc, "%d", strlen(value));

    int req_len = 19 + strlen(key) + strlen(flagsc) + strlen(exptimec) + strlen(value_lenc) + strlen(value);
    char *req = (char*)malloc(req_len);
    char *pof = req;

    req[0] = 0;
    req[1] = 0;
    req[2] = 0;
    req[3] = 0;
    req[4] = 0;
    req[5] = 1;
    req[6] = 0;
    req[7] = 0;
    pof += 8;

    memcpy(pof, "set ", 4); pof += 4;
    memcpy(pof, key, strlen(key)); pof += strlen(key);
    memcpy(pof, " ", 1); pof += 1;
    memcpy(pof, flagsc, strlen(flagsc)); pof += strlen(flagsc);
    memcpy(pof, " ", 1); pof += 1;
    memcpy(pof, exptimec, strlen(exptimec)); pof += strlen(exptimec);
    memcpy(pof, " ", 1); pof += 1;
    memcpy(pof, value_lenc, strlen(value_lenc)); pof += strlen(value_lenc);
    memcpy(pof, "\r\n", 2); pof += 2;
    memcpy(pof, value, strlen(value)); pof += strlen(value);
    memcpy(pof, "\r\n", 2); pof += 2;

    boost::system::error_code err;

    socket->send_to(buffer(req, req_len), *receiver_endpoint, 0, err);

    if (err.value() != 0) {
        std::cout << "Error sending key " << key << ". Code: " << err.value() << std::endl;
    }
}

/* write objects with random values to Memcached cache */
void mc_fill_objects(ip::udp::socket *socket, ip::udp::endpoint *receiver_endpoint, kv_object *objects, int count)
{
    for (int i = 0; i < count; i++)
    {
        auto object = objects[i];
        auto value = gen_random_string(object.value_len);
        //memcached_return_t rc = memcached_set(memc, object.key.c_str(), strlen(object.key.c_str()), value.c_str(), strlen(value.c_str()), (time_t)0, (uint32_t)0);
        do_udp_set_request(object.key, value, 0, 0, socket, receiver_endpoint);
        std::this_thread::sleep_for(std::chrono::microseconds(500));
        if (i % (count / 100) == 0) {
            std::cout << "\rFilling objects " << (i * 100 / count) << "%" << std::flush;
        }
    }
}

/* sends a get request to Memcached via UDP and stores the time of request in request_times (key=request_id) */
void do_udp_get_request(std::string skey, ip::udp::socket *socket, ip::udp::endpoint *receiver_endpoint)
{
    const char *key = skey.c_str();
    const int key_len = skey.length();

    int req_len = 14 + strlen(key);
    char *req = (char*)malloc(req_len);

    // Frame Header
    req[0] = (request_id >> 8);
    req[1] = request_id & 0xFF;
    req[2] = 0;
    req[3] = 0;
    req[4] = 0;
    req[5] = 1;
    req[6] = 0;
    req[7] = 0;

    // GET
    memcpy(req + 8, "get ", 4);

    memcpy(req + 12, key, key_len);                 //memcpy(req + 12, key, strlen(key));
    memcpy(req + 12 + key_len, "\r\n", 2);          //memcpy(req + 12 + strlen(key), "\r\n", 2);

    boost::system::error_code err;

    auto request_time = std::chrono::high_resolution_clock::now();
    socket->send_to(buffer(req, req_len), *receiver_endpoint, 0, err);

    if (err.value() == 0 /* success */) {
        // ToDo: Maybe use key (or key+request_id) instead of just request_id ???
        rtm.lock();
        request_times.insert(std::pair<uint16_t, std::chrono::time_point<std::chrono::high_resolution_clock>>(request_id, request_time));
        rtm.unlock();

        request_id++;
        num_requests++;
    }
}

/* task that schedules and creates requests to the Memcached server */
void schedule_task(kv_object *objects, int count, ip::udp::socket *socket, ip::udp::endpoint *memc_remote)
{
    int64_t test_time_remaining = 0;  // used for priting the remaining time

    auto time_now = std::chrono::high_resolution_clock::now();
    auto end_time = time_now + std::chrono::seconds(test_duration_seconds);
    std::chrono::time_point<std::chrono::high_resolution_clock> sleep_until;

    while (time_now < end_time)
    {
        time_now = std::chrono::high_resolution_clock::now();
        sleep_until = time_now + std::chrono::milliseconds(1000);

        for (int i = 0; i < count; i++)
        {
            if (objects[i].next_call <= time_now)
            {
                do_udp_get_request(objects[i].key, socket, memc_remote);

                objects[i].next_call = time_now + std::chrono::milliseconds(objects[i].irt_ms);
                if (objects[i].next_call < sleep_until)
                {
                    sleep_until = objects[i].next_call;
                }
            }
        }

        if (std::chrono::duration_cast<std::chrono::seconds>(end_time - time_now).count() != test_time_remaining) {
            test_time_remaining = std::chrono::duration_cast<std::chrono::seconds>(end_time - time_now).count();
            std::cout << "\rRemaining time: " << test_time_remaining << "s" << std::flush;
        }

        //std::this_thread::sleep_until(sleep_until);  // may make the request bursty
    }
}

/* schedule_task but for Zipf distribution */
void zipf_task(kv_object *objects, int count, ip::udp::socket *socket, ip::udp::endpoint *memc_remote, int total_no_requests)
{
    //double alpha = 0.99;
    std::vector<double> zipf_dist(count);
    std::vector<double> zipf_dist_new(count-1);
    double zipf_norm = 0.0;
    for (int i = 1; i<= count; i++) {
        zipf_dist[i-1] = 1.0 / pow(i, alpha);
        zipf_norm += zipf_dist[i-1];
    }

    for (int i = 0; i < count; i++) {
        zipf_dist[i] /= zipf_norm;
    }
    //double zipf_dist_new[count-1];
    for (int i = 0; i < count-1; i++) {
        zipf_dist_new[i] = zipf_dist[i];
        std::cout<<"New ZIPF Dist = "<< zipf_dist_new[i]<<std::endl;
    }

    int64_t test_time_remaining = 0;  // used for priting the remaining time

    auto time_now = std::chrono::high_resolution_clock::now();
    auto end_time = time_now + std::chrono::seconds(test_duration_seconds);
    int counter_objects[count-1] = {0};
    std::random_device rd;
    std::mt19937 gen(rd());
    std::discrete_distribution<int> d(zipf_dist_new.begin(), zipf_dist_new.end());

    auto start_time = std::chrono::high_resolution_clock::now();
    double RequestPerSec = total_no_requests / test_duration_seconds;
    double RequestInterval = 1.0 / RequestPerSec;
    double counter_sum = 0;
    for (int i = 0; i < total_no_requests; i++) {

        time_now = std::chrono::high_resolution_clock::now();
        int k = d(gen);
        counter_objects[k] += 1;
        do_udp_get_request(objects[k].key, socket, memc_remote);
        auto elapsed_time = std::chrono::high_resolution_clock::now() - start_time;
        double time_since_start = std::chrono::duration<double>(elapsed_time).count();
        double next_request_time = (i+1) * RequestInterval;
        double sleep_time = next_request_time - time_since_start;
        if (std::chrono::duration_cast<std::chrono::seconds>(end_time - time_now).count() != test_time_remaining) {
            test_time_remaining = std::chrono::duration_cast<std::chrono::seconds>(end_time - time_now).count();
            std::cout << "\rRemaining time: " << test_time_remaining << "s" << std::flush;
        }

        if (sleep_time > 0) {
            std::this_thread::sleep_for(std::chrono::duration<double>(sleep_time));
        }
    }

    // To print the frequency of objects sent
    for (int i = 0; i < count-1; i++) {
        std::cout << counter_objects[i] << " ";
        counter_sum += counter_objects[i];
    }
    std::cout << "Counter Sum = "<< counter_sum;
    std::cout << std::endl;
}

/* schedule_task but for Uniform distribution */
void uniform_task(kv_object *objects, int count, ip::udp::socket *socket, ip::udp::endpoint *memc_remote, int total_no_requests)
{
    int64_t test_time_remaining = 0;  // used for priting the remaining time

    auto time_now = std::chrono::high_resolution_clock::now();
    auto end_time = time_now + std::chrono::seconds(test_duration_seconds);

    auto start_time = std::chrono::high_resolution_clock::now();
    double RequestPerSec = total_no_requests / test_duration_seconds;
    double RequestInterval = 1.0 / RequestPerSec;
    double counter_sum = 0;
    for (int i = 0; i < total_no_requests; i++) {

        time_now = std::chrono::high_resolution_clock::now();
        int k = rand() % (count - 1);
        do_udp_get_request(objects[k].key, socket, memc_remote);
        auto elapsed_time = std::chrono::high_resolution_clock::now() - start_time;
        double time_since_start = std::chrono::duration<double>(elapsed_time).count();
        double next_request_time = (i+1) * RequestInterval;
        double sleep_time = next_request_time - time_since_start;
        if (std::chrono::duration_cast<std::chrono::seconds>(end_time - time_now).count() != test_time_remaining) {
            test_time_remaining = std::chrono::duration_cast<std::chrono::seconds>(end_time - time_now).count();
            std::cout << "\rRemaining time: " << test_time_remaining << "s" << std::flush;
        }

        if (sleep_time > 0) {
            std::this_thread::sleep_for(std::chrono::duration<double>(sleep_time));
        }
    }
}

/* task that receives requests from the Memcached server (run in a separate thread) */
void receive_memc_response_task(ip::udp::socket *socket, ip::udp::endpoint *memc_remote)
{
    auto start_time = std::chrono::high_resolution_clock::now();
    while (true) {
        const auto a = 8+6+key_length; // frame header + "VALUE " + key
        boost::array<char, a> recv_buf;
        size_t len = socket->receive_from(buffer(recv_buf), *memc_remote);

        auto receive_time = std::chrono::high_resolution_clock::now();

        char *data = recv_buf.data();

        uint16_t request_id = (data[0] << 8) + (uint8_t)data[1];  // use bitwise or instead of +
        bool is_hit = (data[8] == 'V');  // cache response starts with "VALUE" if hit, else with "END"

        rtm.lock();
        if (request_times.count(request_id)) {
            auto request_time = request_times.at(request_id);
            request_times.erase(request_id);
            rtm.unlock();

            uint32_t response_time_us = std::chrono::duration_cast<std::chrono::microseconds>(receive_time - request_time).count();

            response_list.emplace_back(response_record{
                .request_id = request_id,
                .timestamp_us = std::chrono::duration_cast<std::chrono::microseconds>(receive_time - start_time).count(),
                .response_time_us = response_time_us,
                .letheinfo_hdr = (uint16_t)data[7],  // TODO: Add data[6] if needed in the future
                .is_hit = is_hit
            });
        } else {
            rtm.unlock();
        }
    }
}

/* print the test results in human- and computer-readable form to stdout */
void print_results()
{
    // Calculate results
    int num_hits = 0;
    int num_misses = 0;
    uint64_t response_time_sum = 0;
    int num_cold_responses = 0;
    int num_warm1_responses = 0;
    int num_warm2_responses = 0;
    int num_hot_responses = 0;
    int num_database_responses = 0;
    int num_cache_miss_db_hit = 0;
    int num_cache_responses = 0;

    for (auto resp : response_list) {
        if (resp.is_hit) {
            num_hits++;

            int hotness = resp.letheinfo_hdr & 0b00000111;
            if (hotness == 0)
                num_cold_responses++;
            else if (hotness == 1)
                num_warm1_responses++;
            else if (hotness == 2)
                num_hot_responses++;
            else if (hotness == 3)
                num_warm2_responses++;
            else
                std::cout << "HOTness unknown: " << hotness << std::endl;

            bool is_db_response = (resp.letheinfo_hdr >> 4) & 1;
            if (is_db_response && hotness == 0)
                num_database_responses++;
            else if (is_db_response && hotness != 0)
                num_cache_miss_db_hit++;
            else
                num_cache_responses++;

        } else {
            num_misses++;
        }

        response_time_sum += resp.response_time_us;
    }

    auto num_responses_received = num_hits + num_misses;
    auto avg_response_time = response_time_sum / num_responses_received;
    float hit_rate = (float)num_hits / (float)num_responses_received;
    float miss_rate = (float)num_misses / (float)num_responses_received;
    auto lost_requests = num_requests - num_responses_received;
    auto lost_requests_percent = (float)lost_requests / (float)num_requests * 100.0;

    // Print results human-readable
    std::cout << "\n ===== Results =====" << std::endl;
    std::cout << num_requests << " requests were made and " << num_responses_received <<" responses were received. ";
    std::cout << "Lost " << lost_requests << " requests (" << lost_requests_percent << "%)" << std::endl;
    std::cout << "Of received responses: Hit-rate: " << hit_rate * 100.0 << "% (" << num_hits << ") - ";
    std::cout << "Miss-rate: " << miss_rate * 100.0 << "% (" << num_misses << ")" << std::endl;
    std::cout << "The average response time was " << avg_response_time << " microseconds" << std::endl;
    std::cout << "HOT: " << num_hot_responses << " - WARM1: " << num_warm1_responses << " - WARM2: " << num_warm2_responses << " - COLD: " << num_cold_responses << std::endl;
    std::cout << "DB+COLD: " << num_database_responses << " - DB+WARM/HOT(Cache Miss): " << num_cache_miss_db_hit << " - Cache+WARM/HOT: " << num_cache_responses << "\n" << std::endl;

    // Print results computer-readable (JSON)
    char str[1024];
    sprintf(str, "{\"testprogram\": \"mcloadgen_static\", \"num_objects\": %d, \"duration\": %d, \"min_value_size\": %d, \"max_value_size\": %d, \"exp_dist_mean\": %f, \"exp_dist_lambda\": %f, \"num_requests\": %u, \"num_responses_received\": %u, \"num_hits\": %u, \"num_misses\": %u, \"num_hot_responses\": %u, \"num_warm1_responses\": %u, \"num_warm2_responses\": %u, \"num_cold_responses\": %u, \"num_database_responses\": %u, \"num_cache_miss_db_hit\": %u, \"num_cache_responses\": %u, \"avg_response_time_us\": %lu}",
        num_objects, test_duration_seconds, value_size_min, value_size_max, exp_dist_mean, exp_dist_lambda, num_requests, num_responses_received, num_hits, num_misses, num_hot_responses, num_warm1_responses, num_warm2_responses, num_cold_responses, num_database_responses, num_cache_miss_db_hit, num_cache_responses, avg_response_time);
    std::cout << "COMPUTER_READABLE: " << str << std::endl;
}

/* generates a csv file with all responses */
void generate_csv(const std::string filename)
{
    std::ofstream csvf(filename);

    csvf << "timestamp_us,request_id,response_time_us,is_hit,hotness,db_response,cache_id\n";

    for (auto resp : response_list) {
        int hotness = resp.letheinfo_hdr & 0b00000111;
        bool db_response = (resp.letheinfo_hdr >> 4) & 1;
        int cache_id = (resp.letheinfo_hdr >> 5) & 0b00000111;

        csvf << resp.timestamp_us << "," << resp.request_id << "," << resp.response_time_us << "," << resp.is_hit << "," << hotness << "," << db_response << "," << cache_id << ",\n";
    }

    csvf.close();
}

bool parse_cmdline(int argc, char const *argv[])
{
    if (argc < 7) {
        std::cout << "Error. Syntax: " << argv[0] << " <ip e.g. 127.0.0.1> <distribution> <number of objects> <Max requests limit> <Run ID> <Zipf alpha, e.g. 99 for 0.99>" << std::endl;
        std::cout << "Available distributions: 0=Exponential inter-request times 1=Zipf popularity per object 2=Uniform" << std::endl;
        return false;
    }

    memc_host = argv[1];
    strcpy(memc_config, "--SERVER=");
    strcat(memc_config, argv[1]);
    strcat(memc_config, ":");
    strcat(memc_config, std::to_string(memc_tport).c_str());

    distribution_type = std::stoi(argv[2]);

    num_objects = std::stoi(argv[3]);

    total_request_limit = std::stoi(argv[4]);

    run_id = std::stoi(argv[5]);

    alpha = (double)std::stoi(argv[6]) / 100.0;

    return true;
}

int main(int argc, char const *argv[])
{
    std::srand(static_cast<long unsigned int>(time(0)));

    std::cout << "Very fast Memcached load generator" << std::endl;
    std::cout << "David Munstein @ NCS, October 2022" << std::endl;

    // parse cmdline arguments
    if (!parse_cmdline(argc, argv)) {
        return 1;
    }

    std::cout << "Variables: " << num_objects << " objects - Time: " << test_duration_seconds << "s - Run ID: " << run_id << " - Total request limit: " << total_request_limit << std::endl;
    switch (distribution_type) {
        case 0:
            std::cout << "Distribution: Exponential inter-request times" << std::endl;
            break;
        case 1:
            std::cout << "Distribution: Zipf object popularities - Alpha: " << alpha << std::endl;
            break;
        case 2:
            std::cout << "Distribution: Uniform object popularities" << std::endl;
            break;
        default:
            std::cout << "No distribution no. " << distribution_type << std::endl;
            return 1;
            break;
    }

    // allocate, generate (random) and sort objects
    kv_object *objects = (kv_object *)malloc(num_objects * sizeof(kv_object));
    generate_random_kvobjects(objects, num_objects);
    if (distribution_type == 0) {
        sort_objects_irt_asc(objects, num_objects);
    }

    io_service io_service;
    ip::udp::socket *socket = new ip::udp::socket(io_service);
    ip::udp::endpoint *memc_remote = new ip::udp::endpoint(ip::address::from_string(memc_host), memc_uport);
    socket->open(ip::udp::v4());

    // write all objects to cache
    mc_fill_objects(socket, memc_remote, objects, num_objects);

    // receive responses on separate thread
    // TODO: Use Mutex or single thread with non-blocking receive instead (tested current solution and works good enough for now)
    boost::thread receive_memc_response_thread(receive_memc_response_task, socket, memc_remote);

    // schedule sending requests (exponential static inter-request times)
    if (distribution_type == 0) {
        schedule_task(objects, num_objects, socket, memc_remote);
    }
    // schedule sending requests (Zipf popularity per object)
    else if (distribution_type == 1) {
        zipf_task(objects, num_objects, socket, memc_remote, total_request_limit);
    }
    // schedule sending requests (Uniform)
    else {
        uniform_task(objects, num_objects, socket, memc_remote, total_request_limit);
    }

    // print results
    print_results();

    // store results to csv file
    std::string file_name = "test/mclgs_results" + std::to_string(run_id) + ".csv";
    generate_csv(file_name);

    std::cout << "test run " << run_id << " completed." << std::endl;
    return 0;
}
