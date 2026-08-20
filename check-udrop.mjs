import { neon } from '@neondatabase/serverless';
const sql = neon(process.argv[2]);
sql`SELECT udrop_key1, udrop_key2 FROM settings LIMIT 1`.then(rows => {
  console.log(JSON.stringify(rows));
}).catch(err => {
  console.error('Error:', err.message);
});