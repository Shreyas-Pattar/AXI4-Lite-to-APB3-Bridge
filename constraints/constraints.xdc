# Define 100 MHz clock on the aclk port

# Set basic I/O delays for out-of-context standalone synthesis/timing (optional, 2 ns margin)

create_clock -period 10.000 -name aclk [get_ports aclk]
