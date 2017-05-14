FROM mongo:3.4

COPY docker-entrypoint-override.sh /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/docker-entrypoint-override.sh"]
EXPOSE 27017
CMD ["mongod"]
