// Runtime configuration belongs in environment variables, never in source control.
// The names retain the original module API so the rest of the learning app is unchanged.
module.exports = Object.freeze({
    DB_HOST: process.env.DB_HOST || '',
    DB_USER: process.env.DB_USER || '',
    DB_PWD: process.env.DB_PWD || '',
    DB_DATABASE: process.env.DB_DATABASE || 'webappdb'
});
