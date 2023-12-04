# Memcached Load Generator/Test Client "mcloadgen_static"

Test client for generating a Memcached load consisting of GET requests via UDP. Implemented in C++.  
The test client will generate a "static load" which means that object keys and values are not changed over the test duration.
Depending on the distribution, the inter-request times are static as well or might encounter a variation due to the randomness of chosen objects.
The test client will store all generated objects to the Memcached server (SET) with infinite expiration time at the beginning of the test. Then the test client will only request objects (GET) from the Memcached server.

## Usage

Make sure you have following dependencies: A **C++ compiler**, the **Boost C++ libraries** (especially libboost_system and libboost_threads)

1. Configure the test client by changing values in `testvariables.h`

Variable | Default | Explaination
---------|---------|-------------
IRT_EXP_DIST_MEAN | 1.0 | Mean value of the exponential distribution used for inter-request times (distribution 0)
KEY_LENGTH | 44 | Length of the Memcached keys in bytes/characters
VALUE_SIZE_MIN | 200 | Minimum size in bytes of objects when generating random values
VALUE_SIZE_MAX | 300 | Maximum size in bytes of objects when generating random values
TEST_DURATION_SECONDS | 10 | Duration of the test in seconds

2. Build the test client by running `make`
3. Run the test client using `./mcloadgen_static <server ip> <distribution> <number of objects> <Max requests limit> <Run ID> <Alpha>`

Parameter | Example | Explaination
----------|---------|-------------
server ip | 127.0.0.1 | IP address of the Memcached server
distribution | 1 | See list below
number of objects | 1000 | Number of random objects to generate. Each object receives a popularity or inter-request time, depending on the algorithm. While running, the test client will choose objects to request using their popularity/inter-request times.
Max requests limit |  | Maximum number of requests the client will generate. Request rate for each run is limited to `n/test_duration` requests per second.
Run ID |  | Integer used for the output filename: `test/mclgs_results<Run ID>.csv`
Alpha |  | Alpha value without decimal point used for the Zipf distribution (e.g. `95` for alpha `0.95`)

## Available distributions

0. **Exponential random inter-request times**  
   Each object gets a random (exponential) generated inter-request time t_irt. The client tries to request an object in its interval t_irt.
1. **Zipf distributed object popularities**  
   Each object gets a popularity (Zipf). The client chooses objects to request using their popularity.
2. **Uniform distributed object popularities**  
   Each object gets the same popularity. The client chooses objects to request using their popularity.

## Algorithm Pseudocode (Distribution 0, Exponential IRT)
```python
# Generate random objects (random key, inter-request times, ...)
objects = generate_random_kvobjects(NUM_OBJECTS)

# Store request times for each request id (sequence number from Memcached UDP frame header)
request_times = {}

# Write all objects to the Memcached server using UDP
# TTL=0 (infinity expiration time), random values are generated for each object
mc_fill_objects(NUM_OBJECTS, VALUE_SIZE_MIN, VALUE_SIZE_MAX)

# Create a second thread to receive UDP responses
def receive_memc_response_task():
    [Memcached UDP packet received]:
        response_time = get_current_time() - request_times[packet.request_id]

# Send the objects with the previously generated inter-request times
def schedule_task(objects):
    [choose object with "next_call <= time_now"]:
        request_id = send_get_request_via_udp(object)
        request_times[request_id] = get_current_time()
        next_call = time_now + object.inter_request_time
```

## Algorithm Pseudocode (Distribution 1, Zipf Distribution)
```python
# Generate random objects (random key, ...)
objects = generate_random_kvobjects(NUM_OBJECTS)

# Write all objects to the Memcached server using UDP
# TTL=0 (infinity expiration time), random values are generated for each object
mc_fill_objects(NUM_OBJECTS, VALUE_SIZE_MIN, VALUE_SIZE_MAX)

# Create a second thread to receive UDP responses
def receive_memc_response_task():
    [Memcached UDP packet received]:
        response_time = get_current_time() - request_times[packet.request_id]

# Send objects
def schedule_task(objects):
    while True:
        i = <Zipf Algorithm>
        object = objects[i]
        request_id = send_get_request_via_udp(object)
        request_times[request_id] = get_current_time()
```


### Helper scripts

The folder also contains helper scripts than can be used to run the test client multiple times for different values and also contains an evaluation script. Please note that the scripts are partly untested and the final evaluation of Lethe was done manually.
