import http from 'k6/http';
import { sleep, check } from 'k6';

export let options = {
  vus: 10,
  duration: '15s',
};

export default function () {
  const res = http.get('http://content-service-canary.default.svc.cluster.local/');
  check(res, { 'status 200': (r) => r.status === 200 });
  sleep(1);
}
