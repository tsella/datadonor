const Bonjour = require('bonjour-service');
const bonjour = new Bonjour.Bonjour();

console.log('Searching for _datadonor._tcp services on the network...');
console.log('Listening for broadcasts... (Press Ctrl+C to exit)');

const browser = bonjour.find({ type: 'datadonor' }, function (service) {
  console.log('\n✅ Discovered DataDonor Service!');
  console.log('Name:', service.name);
  console.log('Host:', service.host);
  console.log('Port:', service.port);
  console.log('Type:', service.type);
  console.log('Addresses:', service.addresses);
  console.log('TXT Records:', service.txt);
  console.log('----------------------------------------\n');
});

browser.start();
