CXX=g++
CXXFLAGS=-O3
LDFLAGS=-lboost_system -pthread -lboost_thread  # -lmemcached

mcloadgen_static: mcloadgen_static.cpp testvariables.h
	$(CXX) $(CXXFLAGS) -o mcloadgen_static mcloadgen_static.cpp $(LDFLAGS)

run: mcloadgen_static
	./mcloadgen_static
