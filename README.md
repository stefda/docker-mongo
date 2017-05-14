# mongo

An override of the official [mongo image](https://hub.docker.com/_/mongo/) that
allows to set up username, password and database via docker-compose environment
variables.

# Usage

An example docker-compose.yml looks like this:

```yaml
version: '2'
services:
  mongo:
    image: stefda/mongo
    environment:
      USERNAME: myusername
      PASSWORD: mypassword
      DATABASE: mydatabase
    ports:
      - 27017:27017
```

To connect, one must authenticate against the `admin` database:

```bash
mongo --host <docker_ip> --authenticationDatabase admin -u myusername -p mypassword mydatabase 
```
