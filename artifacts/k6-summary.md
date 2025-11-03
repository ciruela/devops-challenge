# k6 Summary

Generated: Mon Nov  3 17:50:14 -03 2025

\n## Blue/Green

- checks:      checks.........................: 100.00% ✓ 400       ✗ 0   
- data_received:      data_received..................: 98 kB   4.9 kB/s
- data_sent:      data_sent......................: 43 kB   2.1 kB/s
- http_req_duration:      http_req_duration..............: avg=2.72ms   min=260.66µs med=1.54ms   max=22.24ms  p(90)=4.4ms    p(95)=7.88ms  
- http_req_failed:      http_req_failed................: 0.00%   ✓ 0         ✗ 400 
- http_reqs:      http_reqs......................: 400     19.913641/s
- iterations:      iterations.....................: 400     19.913641/s
- vus_max:      vus_max........................: 20      min=20      max=20

\n## Canary

- checks:      checks.........................: 100.00% ✓ 150    ✗ 0   
- data_received:      data_received..................: 37 kB   2.4 kB/s
- data_sent:      data_sent......................: 17 kB   1.1 kB/s
- http_req_duration:      http_req_duration..............: avg=3.25ms   min=770.75µs med=2.01ms   max=15.73ms  p(90)=7.79ms   p(95)=10.82ms 
- http_req_failed:      http_req_failed................: 0.00%   ✓ 0      ✗ 150 
- http_reqs:      http_reqs......................: 150     9.9399/s
- iterations:      iterations.....................: 150     9.9399/s
- vus_max:      vus_max........................: 10      min=10   max=10

