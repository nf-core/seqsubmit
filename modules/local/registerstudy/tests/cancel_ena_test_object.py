#!/usr/bin/env python3
from __future__ import annotations

import base64
import datetime
import os
import sys
import urllib.request

accession = sys.argv[1]
timestamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
username = os.environ["ENA_WEBIN"]
password = os.environ["ENA_WEBIN_PASSWORD"]

xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<WEBIN>
  <SUBMISSION_SET>
    <SUBMISSION alias="cancel-{accession}-{timestamp}">
      <ACTIONS>
        <ACTION>
          <CANCEL target="{accession}"/>
        </ACTION>
      </ACTIONS>
    </SUBMISSION>
  </SUBMISSION_SET>
</WEBIN>
""".encode()

token = base64.b64encode(f"{username}:{password}".encode()).decode()
request = urllib.request.Request(
    "https://wwwdev.ebi.ac.uk/ena/submit/webin-v2/submit",
    data=xml,
    headers={
        "Authorization": f"Basic {token}",
        "Content-Type": "application/xml",
        "Accept": "application/xml",
    },
)

with urllib.request.urlopen(request) as response:
    print(response.read().decode())
