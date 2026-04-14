#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { NasboxIotStack } from '../lib/nasbox-iot-stack';

const app = new cdk.App();

new NasboxIotStack(app, 'NasboxIotStack', {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});
