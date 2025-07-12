#!/bin/bash

## Release Name
#
HOSTNAME_DEFAULT=${HOSTNAME//\./-}
if [ -n "$AUTO_DOMAIN" ]; then
    TAK_ALIAS=${AUTO_DOMAIN//\./-}
    echo "TAK release alias: ${TAK_ALIAS} (automated)"
else
    prompt "Name your TAK release alias [${HOSTNAME_DEFAULT}] :" TAK_ALIAS
    TAK_ALIAS=${TAK_ALIAS:-${HOSTNAME_DEFAULT}}
fi

## TAK URI 
#
if [ -n "$AUTO_DOMAIN" ]; then
    TAK_URI=${AUTO_DOMAIN}
    echo "TAK URI: ${TAK_URI} (automated)"
else
    prompt "What is the URI (FQDN, hostname, or IP) [${IP_ADDRESS}] :" TAK_URI
    TAK_URI=${TAK_URI:-${IP_ADDRESS}}
fi

## DB Password
#
passgen ${DB_PASS_OMIT}
TAK_DB_PASS=${PASSGEN}
#prompt "TAK Database Password: Default [${TAK_DB_PASS}] :" DB_PASS_INPUT
#TAK_DB_PASS=${DB_PASS_INPUT:-${TAK_DB_PASS}}

if [[ "${INSTALLER}" == "docker" ]];then 
	TAK_DB_ALIAS=tak-database
else	
	TAK_DB_ALIAS=127.0.0.1
fi 


## CA Info
#
if [ -z "$AUTO_DOMAIN" ]; then
    msg $info "\n\nCertificate Information (you can accept all the defaults)"
fi

ORGANIZATION_DEFAULT="tak-tools"
if [ -n "$AUTO_DOMAIN" ]; then
    ORGANIZATION=${ORGANIZATION_DEFAULT}
    echo "Certificate Organization: ${ORGANIZATION} (automated)"
else
    prompt "Certificate Organization [${ORGANIZATION_DEFAULT}] :" ORGANIZATION
    ORGANIZATION=${ORGANIZATION:-${ORGANIZATION_DEFAULT}}
fi

ORGANIZATIONAL_UNIT_DEFAULT="tak"
if [ -n "$AUTO_DOMAIN" ]; then
    ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT_DEFAULT}
    echo "Certificate Organizational Unit: ${ORGANIZATIONAL_UNIT} (automated)"
else
    prompt "Certificate Organizational Unit [${ORGANIZATIONAL_UNIT_DEFAULT}] :" ORGANIZATIONAL_UNIT
    ORGANIZATIONAL_UNIT=${ORGANIZATIONAL_UNIT:-${ORGANIZATIONAL_UNIT_DEFAULT}}
fi

CITY_DEFAULT="XX"
if [ -n "$AUTO_DOMAIN" ]; then
    CITY=$(uppercase "${CITY_DEFAULT}")
    echo "Certificate City: ${CITY} (automated)"
else
    prompt "Certificate City [${CITY_DEFAULT}] :" CITY
    CITY=$(uppercase "${CITY:-${CITY_DEFAULT}}")
fi

STATE_DEFAULT="XX"
if [ -n "$AUTO_DOMAIN" ]; then
    STATE=$(uppercase "${STATE_DEFAULT}")
    echo "Certificate State: ${STATE} (automated)"
else
    prompt "Certificate State [${STATE_DEFAULT}] :" STATE
    STATE=$(uppercase "${STATE:-${STATE_DEFAULT}}")
fi

COUNTRY_DEFAULT="US"
if [ -n "$AUTO_DOMAIN" ]; then
    COUNTRY=$(uppercase "${COUNTRY_DEFAULT}")
    echo "Certificate Country: ${COUNTRY} (automated)"
else
    prompt "Certificate Country (two letter abbreviation) [${COUNTRY_DEFAULT}] :" COUNTRY
    COUNTRY=$(uppercase "${COUNTRY:-${COUNTRY_DEFAULT}}")
fi

CA_PASS_DEFAULT="atakatak"
if [ -n "$AUTO_DOMAIN" ]; then
    CA_PASS=${CA_PASS_DEFAULT}
    echo "Certificate Authority Password: [REDACTED] (automated)"
else
    prompt "Certificate Authority Password [${CA_PASS_DEFAULT}] :" CA_PASS
    CA_PASS=${CA_PASS:-${CA_PASS_DEFAULT}}
fi

CERT_PASS_DEFAULT="atakatak"
if [ -n "$AUTO_DOMAIN" ]; then
    CERT_PASS=${CERT_PASS_DEFAULT}
    echo "Client Certificate Password: [REDACTED] (automated)"
else
    prompt "Client Certificate Password [${CERT_PASS_DEFAULT}] :" CERT_PASS
    CERT_PASS=${CERT_PASS:-${CERT_PASS_DEFAULT}}
fi

CLIENT_VALID_DAYS_DEFAULT="30"
if [ -n "$AUTO_DOMAIN" ]; then
    CLIENT_VALID_DAYS=${CLIENT_VALID_DAYS_DEFAULT}
    echo "Client Certificate Validity: ${CLIENT_VALID_DAYS} days (automated)"
else
    prompt "Client Certificate Validity Duration (days) [${CLIENT_VALID_DAYS_DEFAULT}] :" CLIENT_VALID_DAYS
    CLIENT_VALID_DAYS=${CLIENT_VALID_DAYS:-${CLIENT_VALID_DAYS_DEFAULT}}
fi


## LetsEncrypt (optional)
#
if [ -z "$AUTO_EMAIL" ]; then
    msg $info "\n\nLetsEncrypt"
fi

if [ -n "$AUTO_EMAIL" ]; then
    LE_ENABLE=true
    LE_EMAIL="$AUTO_EMAIL"
    LE_VALIDATOR="web"
    echo "LetsEncrypt enabled: YES (automated)"
    echo "LetsEncrypt email: ${LE_EMAIL} (automated)"
    echo "LetsEncrypt validator: ${LE_VALIDATOR} (automated)"
else
    LE_ENABLE=false
    LE_EMAIL=""
    LE_VALIDATOR="none"

    prompt "Enable LetsEncrypt [y/N] :" LE_PROMPT
    if [[ ${LE_PROMPT} =~ ^[Yy]$ ]];then
        LE_ENABLE=true

        prompt "LetsEncrypt Confirmation Email:" LE_EMAIL

        prompt "LetsEncrypt Validator (web/dns):" LE_VALIDATOR
        if [[ "${LE_VALIDATOR}" != "web" && "${LE_VALIDATOR}" != "dns" ]]; then
            LE_VALIDATOR="dns"
        fi
    fi
fi

