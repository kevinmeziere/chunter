/*
 * This utility provides a SSH door for SmartOS VM's
 * it is based on MerlinDMC's code for a always open
 * SSH door but instead of always allowing access it
 * prints the information to stdout and then reads
 * the response from STDIN (one line).
 *
 * usage: ./zonedoor <uuid> <service>
 * i.e.: ./zonedoor <uuid> _joyent_sshd_key_is_authorized
 * gets: /zones/<uuid>/root/var/tmp/._joyent_sshd_key_is_authorized
 */
 
/*
 * protocol:
 * All data are newline terminated and space sperated commands
 * 
 * Erlang                                            C
 * a<zone-uuid> <doorname> <cookie>         ->       // creates a new zone door in zone <zone-uuid> as the file <doorname>
 * d<zone-uuid> <doorname>                  ->       // deletes the given zone door
 * h                                        ->       // heartbeet to ensure the c program shuts down in the case the communication with erlang fails
 * 
 * //sends a message to the erlang process  <-       <cookie> <message(might include spaces)>
 * r<reply(might include spaces)>           ->       //sends a reply to the last request gotten
 */

#include <zdoor.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>

#define HEARTBEAT 7  	// number of seconds missing HB before exit

#define	TIMEOUT	5	// number of seconds to wait for response


zdoor_result_t *server(zdoor_cookie_t *cookie, char *argp, size_t arpg_sz);
void addVMDoor(char * zoneID, char *doorName, char *doorBiscuit);
void deleteVMDoor(char * zoneID, char *doorName);
zdoor_handle_t zdid;

enum { IDLE,  WAITING, REPLIED } state = IDLE;
pthread_mutex_t	lock = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t	cv = PTHREAD_COND_INITIALIZER;
char		*resp;

void
addVMDoor(char *zoneID, char *doorName, char *doorBiscuit)
{
	char* err = "unknown errror";

	if ((doorBiscuit = strdup(doorBiscuit)) == NULL) {
		(void) fprintf(stderr, "Out of memory?\n");
		return;
	}
	(void) fprintf(stderr, "[zonedoor:%s] opening door '%s' in zone %s.\n",
	    doorBiscuit, doorName, zoneID);
	switch (zdoor_open(zdid, zoneID, doorName, doorBiscuit, server)) {
	case 0:
		return;
	case -1:
		err = "General error";
		break;
	case -2:
		err = "Not the global zone";
		break;
	case -3:
		err = "Zone not running";
		break;
	case -4:
		err = "Zone forbidden";
		break;
	case -5:
		err = "argument error";
		break;
	case -6:
		err = "Out of memory";
		break;
	}
	(void) fprintf(stderr,
	    "Error [zonedoor] opening door '%s' in zone %s: %s.\n",
	    doorName, zoneID, err);
	//  printf("ok\n"); //no sure if responce is necessary. right now chunter_vm_auth does not handle it.
	//  fflush(stdout);
	free(doorBiscuit);
}

void
deleteVMDoor(char *zoneID, char *doorName)
{
	char *biscuit;
	biscuit = zdoor_close(zdid, zoneID, doorName);
	free(biscuit);
	// printf("ok\n");
	// fflush(stdout);
}

zdoor_result_t *
server(zdoor_cookie_t *cookie, char *argp, size_t arpg_sz)
{
	zdoor_result_t *result;
	timespec_t when;

	result = malloc(sizeof (zdoor_result_t));

	pthread_mutex_lock(&lock);
	(void) clock_gettime(CLOCK_REALTIME, &when);
	when.tv_sec += TIMEOUT;

	/* first wait to get to idle state before we send the message */
	while (state != IDLE) {
		if (pthread_cond_timedwait(&cv, &lock, &when) != 0) {
			break;
		}
	}
	if (state != IDLE) {
		pthread_mutex_unlock(&lock);
		(void) fprintf(stderr,
		    "Timed out waiting for IDLE state\n");
		goto failed;
	}
	// send the message
	state = WAITING;
	(void) printf("%s %s\n", (char *)cookie->zdc_biscuit, argp);
	(void) fflush(stdout);
	pthread_cond_signal(&cv);
	pthread_mutex_unlock(&lock);

	// reset the time for now
	(void) clock_gettime(CLOCK_REALTIME, &when);
	when.tv_sec += TIMEOUT;

	// now wait for the reply
	pthread_mutex_lock(&lock);
	while (state != REPLIED) {
		if (pthread_cond_timedwait(&cv, &lock, &when) != 0) {
			break;
		}
	}
	if (state != REPLIED) {
		(void) fprintf(stderr, "Timed out waiting for REPLY\n");
		pthread_mutex_unlock(&lock);
		goto failed;
	}
	result->zdr_data = resp;
	result->zdr_size = strlen(result->zdr_data) + 1;
	resp = NULL;
	state = IDLE;
	pthread_cond_signal(&cv);
	pthread_mutex_unlock(&lock);

	return result;

failed:
	result->zdr_data = strdup("0");	// deny
	result->zdr_size = 2;
	return result;
}


void
sigAlrmHandler(int sig)
{
	exit(0);
}


int
main(int argc, char *argv[])
{

	signal(SIGALRM, sigAlrmHandler);
	alarm(HEARTBEAT);

	zdid = zdoor_handle_init();
	size_t nbytes = 0;
	char *input = NULL;

	for (;;) {

		char *arg1 = NULL;
		char *arg2 = NULL;
		char *arg3 = NULL;

		if (getline(&input, &nbytes, stdin) < 0) {
			(void) fprintf(stderr, "Peer died?\n");
			break;
		}
		switch (input[0]) {
		case 'h':    // heartbeat
			alarm(HEARTBEAT);
			break;

		case 'a':    // add zone door
			arg1 = strtok(input+1, " \n");
			arg2 = strtok(NULL, " \n");
			arg3 = strtok(NULL, " \n");
			if (arg2 != NULL && arg3 != NULL) {
				addVMDoor(arg1, arg2, arg3);
			} else {
				// cannot show input, because it got clobbered
				(void) fprintf(stderr, "Invalid input\n");
			}
        		break;

		case 'd':    // delete zone door
			arg1 = strtok(input+1, " \n");
			arg2 = strtok(NULL, " \n");

			if (arg2 != NULL) {
				deleteVMDoor(arg1, arg2);
			} else {
				// cannot show input, because it got clobbered
				(void) fprintf(stderr, "Invalid input\n");
				free(arg1);
				free(arg2);
			}
			break;

		case 'r':   // request response
			arg1 = strtok(input+1, "\n");
			pthread_mutex_lock(&lock);
			if (state == WAITING) {
				resp = strdup(arg1);
				state = REPLIED;
				pthread_cond_signal(&cv);
			} else {
				(void) fprintf(stderr,
				    "Unexpected response %s in state %d!\n",
				    arg1, state);
			}
			pthread_mutex_unlock(&lock);
			break;

		default:
			break;
		}
  	}

	free(input);
	exit(1);
}
