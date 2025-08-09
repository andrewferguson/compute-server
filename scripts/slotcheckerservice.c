#include<stdio.h>
#include<stdlib.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <assert.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>  // Include this header for fixed-width integer types
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
// master connects to slave and and receives the slot completion status
#define SHARED_MEM_SIZE 4 // Size of shared memory (in bytes)
#define PORT 8080
#define SERVER_PORT 6000

#define MAXLINE 1024
typedef struct {
    char *shmPath;
    void *sharedMem;
    uint64_t size;
    int mapped;
} Host;

#define TYPE_PROXY 1
#define TYPE_COMPONENT 2
typedef struct __attribute__((__packed__)) slot_checker_ack {
    uint8_t type;
    uint32_t id;
    uint8_t slot;
} slot_checker_ack_t;

int16_t slot = 2;

// Function to create a new host mapper
Host* NewHost(const char *shmPath) {
    struct stat st;
    if (stat(shmPath, &st) != 0) {
        perror("stat file");
        return NULL;
    }

    Host *host = (Host *)malloc(sizeof(Host));
    if (!host) {
        perror("malloc");
        return NULL;
    }

    host->shmPath = strdup(shmPath);
    if (!host->shmPath) {
        perror("strdup");
        free(host);
        return NULL;
    }

    host->sharedMem = NULL;
    host->size = 0;
    host->mapped = 0;
    return host;
}

// Function to map the shared memory into the program memory space
int Map(Host *host) {
    int fd = open(host->shmPath, O_RDWR);
    if (fd == -1) {
        perror("open device file");
        return -1;
    }

    struct stat st;
    if (fstat(fd, &st) == -1) {
        perror("stat file");
        close(fd);
        return -1;
    }

    void *sharedMem = mmap(NULL, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (sharedMem == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }

    host->mapped = 1;
    host->sharedMem = sharedMem;
    host->size = st.st_size;
    close(fd);
    return 0;
}

// Function to unmap the shared memory
int Unmap(Host *host) {
    if (munmap(host->sharedMem, host->size) == -1) {
        perror("munmap");
        return -1;
    }
    host->mapped = 0;
    return 0;
}

// Function to get the size of the shared memory space
uint64_t Size(Host *host) {
    return host->size;
}

// Function to get the device path of the shared memory file
const char* DevPath(Host *host) {
    return host->shmPath;
}

// Function to return the already mapped shared memory, panics if Map() didn't succeed
void* SharedMem(Host *host) {
    if (!host->mapped) {
        fprintf(stderr, "tried to access non-mapped memory\n");
        exit(EXIT_FAILURE);
    }
    return host->sharedMem;
}

// Function to ensure the changes made to the shared memory are synced
int Sync(Host *host) {
    if (msync(host->sharedMem, host->size, MS_SYNC) == -1) {
        perror("msync");
        return -1;
    }
    return 0;
}

// Function to write data to shared memory
void WriteToSharedMem(Host *host, const char *data) {
    if (!host->mapped) {
        fprintf(stderr, "tried to write to non-mapped memory\n");
        exit(EXIT_FAILURE);
    }

    size_t data_len = strlen(data) + 1; // Include null terminator
    if (data_len > host->size) {
        fprintf(stderr, "data is too large to fit in shared memory\n");
        exit(EXIT_FAILURE);
    }

    memcpy(host->sharedMem, data, data_len);
}

// Function to read data from shared memory
void ReadFromSharedMem(Host *host, char *buffer, size_t buffer_size) {
    if (!host->mapped) {
        fprintf(stderr, "tried to read from non-mapped memory\n");
        exit(EXIT_FAILURE);
    }

    size_t data_len = strnlen((char*)host->sharedMem, host->size);
    if (data_len >= buffer_size) {
        fprintf(stderr, "buffer is too small to hold the data\n");
        exit(EXIT_FAILURE);
    }

    memcpy(buffer, host->sharedMem, data_len);
    buffer[data_len] = '\0'; // Null terminate the buffer
}


int send_to_switch(int client_fd, int num_to_send, struct sockaddr_in servaddr){

    slot_checker_ack_t ack;
    ack.type = (uint8_t) TYPE_COMPONENT;
    ack.id = (uint32_t) num_to_send;
    ack.slot = (uint8_t) slot;
    sendto(client_fd, &ack, sizeof(ack), MSG_CONFIRM, (const struct sockaddr *) &servaddr, sizeof(servaddr));

}


int bind_for_switch(int port){
    int sock;
    assert((sock = socket(AF_INET, SOCK_DGRAM, 0)) >= 0);

    struct sockaddr_in servaddr;
    memset(&servaddr, 0, sizeof(servaddr));

    // Filling server information
    servaddr.sin_family = AF_INET; // IPv4
    servaddr.sin_addr.s_addr = INADDR_ANY;
    servaddr.sin_port = htons(port);

    // Bind the socket with the server address
    if (bind(sock, (const struct sockaddr *)&servaddr, sizeof(servaddr)) < 0) {
        printf("Failed to bind socket");
        return 1;
    }

    return sock;
}

long long int accept_from_switch(int client_fd){
    int n;
    uint8_t num;
    uint8_t received_num;
    if (recvfrom(client_fd,&received_num, sizeof(received_num), MSG_WAITALL, NULL, NULL) == -1) {
    perror("recvfrom failed");
    return 1;
    }

    slot = received_num;
    if(received_num == 0){
      printf("exit received from switch \n", received_num);
      return -1;
    }



    printf("Received %d from switch \n", received_num);
    return received_num ;
}


int connect_to_switch_udp(){
    int sockfd;
    char *hello = "Hello from client";
    // Creating socket file descriptor
    if ( (sockfd = socket(AF_INET, SOCK_DGRAM, 0)) < 0 ) {
        printf("Failed to create socket");
        return 1;
    }
    return sockfd;

}

// Function to create and bind a socket
int create_socket(struct sockaddr_in *address, int port) {
    int sockfd;
    int opt = 1;

    // Creating socket file descriptor
    if ((sockfd = socket(AF_INET, SOCK_STREAM, 0)) == 0) {
        perror("Socket creation failed");
        exit(EXIT_FAILURE);
    }

    // Setting options for the socket
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR | SO_REUSEPORT, &opt, sizeof(opt))) {
        perror("setsockopt");
        exit(EXIT_FAILURE);
    }

    address->sin_family = AF_INET;
    address->sin_addr.s_addr = INADDR_ANY;
    address->sin_port = htons(port);

    // Bind the socket to the network address and port
    if (bind(sockfd, (struct sockaddr *)address, sizeof(*address)) < 0) {
        perror("Bind failed");
        close(sockfd);
        exit(EXIT_FAILURE);
    }

    return sockfd;
}

// Function to send data
void send_data(int sockfd, const char *message) {
    send(sockfd, message, strlen(message), 0);
    printf("Message sent: %s\n", message);
}

// Function to receive data
void receive_data(int sockfd) {
    char buffer[MAXLINE] = {0};
    int n;

    n = recv(sockfd, buffer, MAXLINE, 0);
    if (n < 0) {
        perror("Receive failed");
        return;
    }

    buffer[n] = '\0'; // Null-terminate the received string
    //printf("Message received: %s\n", buffer);
}





// Global flag to control the loop
volatile sig_atomic_t keep_running = 1;



// Signal handler for SIGINT (Ctrl+C)
void handle_sigint(int sig) {
    keep_running = 0;
}

int main(int argc, char *argv[]){
    int  c_id = atoi(argv[1]);
    const char *shmPath = "/dev/shm/my-little-shared-memory";
    Host *host = NewHost(shmPath);

    if (!host) {
        return 1;
    }

    if (Map(host) != 0) {
        free(host);
        return 1;
    }

    char mbuffer[256];

    int server_fd, new_socket, valread;
    struct sockaddr_in address;
    int opt = 1;
    int addrlen = sizeof(address);
    char buffer[1024] = {0};
    int from_slave_fd = bind_for_switch(PORT);
    int switch_fd = connect_to_switch_udp();

    struct sockaddr_in servaddr;
    memset(&servaddr, 0, sizeof(servaddr));

    // Filling server information
    servaddr.sin_family = AF_INET;
    servaddr.sin_port = htons(SERVER_PORT);
    servaddr.sin_addr.s_addr = inet_addr("192.168.250.1");
    int port = 4322;
    int from_switch_fd = bind_for_switch(port);
    int new_value = 1;

    struct sigaction sa;

    // Set up the sigaction structure to handle SIGINT
    sa.sa_handler = handle_sigint;
    sa.sa_flags = 0; // No special flags
    sigemptyset(&sa.sa_mask); // Do not block additional signals during the handler

    // Set up the SIGINT signal handler
    sigaction(SIGINT, &sa, NULL);
    accept_from_switch(from_switch_fd);
    printf("Switch connected \n");
    sleep(1);
    WriteToSharedMem(host,"S");
    if (Sync(host) != 0) {
        fprintf(stderr, "Failed to sync memory\n");
        }
    while (keep_running) {
        ReadFromSharedMem(host, mbuffer, sizeof(mbuffer));
      //  printf("Read from shared memory: %c\n", mbuffer[0]);
        if(mbuffer[0]=='F'){
//           printf("Slot finished \n");
  //         printf("Sending info to switch\n");
            send_to_switch(switch_fd, c_id, servaddr);
    //        printf("Waiting for switch to complete\n");
            int res = accept_from_switch(from_switch_fd);
        //    printf("Switch completed\n");
          //  printf("Unfreeze the time\n");
            WriteToSharedMem(host,"S");
            if (Sync(host) != 0) {
            fprintf(stderr, "Failed to sync memory\n");
            }
            if(res == -1){
            WriteToSharedMem(host,"I");

            res=accept_from_switch(from_switch_fd);
            while(res!=1){
               sleep(1);
               res=accept_from_switch(from_switch_fd);
               }
           WriteToSharedMem(host,"S");
           printf("Switch connected \n");
           }
            }
        else{
            usleep(1);
        }
        }
    printf("Exiting\n");
    close(new_socket);
    close(server_fd);
    WriteToSharedMem(host,"I");
    if (Unmap(host) != 0) {
        fprintf(stderr, "Failed to unmap memory\n");
    }

    free(host->shmPath);
    free(host);

    return 0;
}
